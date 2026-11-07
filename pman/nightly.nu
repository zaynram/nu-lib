# Install the latest Nushell nightly build: `pman bump-nu`.
#
# Adopted from the owner's `nightly-toolkit` module (a rewrite of nupm's nightly toolkit). `pman` re-exports only
# `bump-nu`; the other exports are helpers that the pman suite tests directly.
#
# A bump never forces a broken binary onto the system: the extracted `nu` is smoke-tested (it must report its
# version and load this library) before any file is moved into place, every replaced file is kept as
# `<name>.previous`, and `--rollback` puts the previous build back. The nightly policy stands — a nightly that
# breaks a module is a defect in the module — but fixing it is done from a working shell.

# ——— imports ——————————————————————————————————————————————————————————————————

use log
use style
use error
use reload

# ——— constants ————————————————————————————————————————————————————————————————

# The releases API of the nightly repository.
export const SOURCE: string = 'https://api.github.com/repos/nushell/nightly/releases'

# The library root (`pman/..`): the smoke test loads it with the new `nu`.
const ROOT: path = path self ..

# The executable suffix of this host's binaries (`nu.exe` on Windows).
const EXE: string = if $nu.os-info.family == windows { '.exe' } else { '' }

# A build's asset name, `nu-<version>-<target>.<ext>`, whose version may carry a `-<tag>.<n>` pre-release part
# (`nu-0.116.2-nightly.33-x86_64-unknown-linux-gnu.tar.gz`, `nu-0.116.0-aarch64-apple-darwin.tar.gz`).
export const ASSET: string = '^nu-(?<version>\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?)-(?<target>[\w-]+)\.(?<ext>tar\.gz|zip|msi)$'

# Run by the newly installed `nu` (`--stdin`): re-registers every plugin of the registry, a plugin shipped in the
# archive from its installed copy, and unregisters each one that fails to load. Input: nuon
# `{registry: path, shipped: record<name: path>}`; output: nuon rows `{name filename action message}`.
const SYNC: string = r#'
let job: record = $in | from nuon
plugin list --registry --plugin-config $job.registry | each {|p|
  let shipped: bool = $job.shipped has $p.name
  let file: string = if $shipped { $job.shipped | get $p.name } else { $p.filename }
  try {
    if ($p.shell | is-empty) {
      plugin add --plugin-config $job.registry $file
    } else {
      plugin add --plugin-config $job.registry --shell $p.shell $file
    }
    {name: $p.name filename: $file action: (if $shipped { "updated" } else { "kept" }) message: null}
  } catch {|e|
    let reason: string = $e.details?.inner?.0?.msg? | default $e.msg
    try {
      plugin rm --plugin-config $job.registry $p.name
      {name: $p.name filename: $p.filename action: "removed" message: $reason}
    } catch {|e2|
      {name: $p.name filename: $p.filename action: "failed" message: $"($reason); not unregistered: ($e2.msg)"}
    }
  }
} | to nuon
'#

# ——— helpers ——————————————————————————————————————————————————————————————————

# The release target of a host: `<arch>-unknown-linux-gnu` (`-musl` with `--musl`), `<arch>-apple-darwin` or
# `<arch>-pc-windows-msvc`.
export def host-target [
  os: record # The host, shaped like `$nu.os-info` (`name`, `arch`)
  --musl # The statically linked musl build, which exists only for Linux
]: nothing -> string {
  match $os.name {
    linux => $'($os.arch)-unknown-linux-(if $musl { "musl" } else { "gnu" })'
    _ if $musl => {
      error raise $"--musl builds exist only for Linux, not '($os.name)'" --kind unsupported
    }
    macos => $'($os.arch)-apple-darwin'
    windows => $'($os.arch)-pc-windows-msvc'
    _ => (error raise $"there are no nightly builds for '($os.name)'" --kind unsupported)
  }
}

# Parse release assets into builds `{name version target ext url digest}`, dropping assets that aren't builds
# (`SHA256SUMS`). `digest` is the `sha256:<hex>` the release metadata lists for the asset, or null.
export def parse-assets []: list<any> -> table {
  where name =~ $ASSET | each {|asset|
    $asset.name | parse --regex $ASSET | first
    | insert name $asset.name
    | insert url $asset.browser_download_url
    | insert digest $asset.digest?
    | select name version target ext url digest
  }
}

# Whether a path is `root` or lies inside it, comparing whole path components after expansion.
export def is-under [
  root: path # The directory that should contain the path
]: path -> bool {
  let target: path = $in | path expand --no-symlink
  try { $target | path relative-to ($root | path expand --no-symlink) | ignore; true } catch { false }
}

# Headers for a request to `url`: GitHub's API gets `Authorization: Bearer $GITHUB_TOKEN` when the variable is
# set (for a higher rate limit); no other host ever receives the token.
export def api-headers [
  url: string # The request URL
]: nothing -> record {
  let token: string = $env.GITHUB_TOKEN? | default ''
  if ($url | url parse | get host) == api.github.com and $token != '' { {Authorization: $'Bearer ($token)'} } else { {} }
}

# The install directory: `dir`, or the running `nu`'s directory. With `--writable`, one outside the home directory
# needs elevated privileges.
def install-dir [
  dir?: path
  --writable # Raise unless the directory can be written: inside the home directory, or elevated
]: nothing -> path {
  let dir: path = $dir | default ($nu.current-exe | path dirname) | path expand --no-symlink
  if $writable and not ($dir | is-under $nu.home-dir) and not (is-admin) {
    error raise $"installing into '($dir)' needs elevated privileges" --with={
      kind: unsupported
      help: 'rerun elevated, or pass an --install-dir inside your home directory'
    }
  }
  $dir
}

# The version a `nu` binary reports (`--version`), or null when the file does not exist or does not run.
# nu-lint-ignore: external_script_as_argument
def binary-version [file: path]: nothing -> oneof<string, nothing> {
  if not ($file | path exists) { return null }
  let res: record = try { ^$file --version | complete } catch { {exit_code: 1 stdout: ''} }
  if $res.exit_code == 0 { $res.stdout | str trim }
}

# The newest release listed by a GitHub-style releases API.
def latest-release [source: string]: nothing -> record {
  log info $'fetching the latest release from ($source)'
  let releases: list = try { http get --headers (api-headers $source) $source } catch {|e|
    $e | error raise $"could not fetch the releases from '($source)'" --kind io
  }
  $releases | sort-by published_at --reverse | get 0?
  | default { error raise $"'($source)' lists no releases" --kind not_found }
}

# The build to install: the archive for `target`, or one chosen from the release's archives.
def pick-build [
  builds: table
  target?: string # The host's target; null to choose interactively
]: nothing -> record {
  let archives: table = $builds | where ext != msi
  if $target == null {
    $archives | input list --display target ('Choose a build' | style paint cyan)
    | default { error raise 'no build chosen: nothing was installed' --kind invalid_argument }
  } else {
    let ext: string = if $target =~ windows { 'zip' } else { 'tar.gz' }
    $archives | where target == $target and ext == $ext | get 0? | default {
      let known: string = $archives | each { get target } | str join ', '
      error raise $"the latest release has no build for '($target)'" --with={
        kind: not_found
        help: $'builds: ($known); choose one with --interactive'
      }
    }
  }
}

# The sha256 a release publishes for a build: the asset's `digest`, else its line in the release's `SHA256SUMS`
# asset (`sums`), else null.
def published-sha256 [build: record sums?: record]: nothing -> oneof<string, nothing> {
  if ($build.digest | default '' | str starts-with 'sha256:') {
    $build.digest | str substring 7.. | str lowercase
  } else {
    $sums | each {|asset|
      let text: string = try { http get --raw $asset.browser_download_url | collect } catch {|e|
        $e | error raise $"could not download '($asset.name)'" --kind io
      } | if ($in | describe) == binary { decode } else { }
      $text | lines | parse --regex '^(?<hash>[0-9a-fA-F]{64}) [ *](?<file>.+)$'
      | where file == $build.name | get 0?.hash | each { str lowercase }
    }
  }
}

# Download a build into `dir` and check it against its published sha256. Only a release that publishes no checksum
# at all (no asset `digest`, no `SHA256SUMS`) is installed unverified; a `SHA256SUMS` that does not list the archive
# is a verification failure like a mismatch, and nothing is installed.
def download [
  build: record
  sums: oneof<record, nothing> # The release's `SHA256SUMS` asset, if any
  dir: path
]: nothing -> path {
  let archive: path = $dir | path join $build.name
  log info $'downloading ($build.url)'
  try { http get --raw $build.url | save --force $archive } catch {|e|
    $e | error raise $"could not download '($build.name)'" --kind io
  }
  let expected: oneof<string, nothing> = published-sha256 $build $sums
  if $expected == null and $sums != null {
    error raise $"($sums.name) does not list '($build.name)'" --with={
      kind: io
      help: "the release's checksum file is incomplete: retry later, or pick another release (--source)"
    }
  }
  if $expected != null {
    let actual: string = open --raw $archive | hash sha256
    if $actual != $expected {
      error raise $"'($build.name)' does not match its published sha256" --with={
        kind: io
        help: $'expected ($expected), got ($actual)'
      }
    }
    log info $'verified the sha256 of ($build.name)'
  }
  $archive
}

# Extract an archive into `dir` and return its `nu` and `nu_plugin_*` binaries, `nu` first.
def extract [archive: path dir: path]: nothing -> list<path> {
  mkdir $dir
  # GNU tar reads the `.tar.gz` builds; the bsdtar of Windows and macOS also reads the `.zip` ones.
  let res: record = ^tar -xf $archive -C $dir | complete
  if $res.exit_code != 0 {
    error raise $"could not extract '($archive | path basename)'" --with={
      kind: external_failure
      help: ($res.stderr | str trim)
    }
  }
  let bins: list<path> = do { cd $dir; glob '**/*' --no-dir } | where {|file|
    let parts: record = $file | path parse
    $parts.extension in ['' exe] and ($parts.stem == nu or ($parts.stem | str starts-with nu_plugin_))
  } | sort-by {|file| ($file | path parse | get stem) != nu }
  if not ($bins | any ($it | path parse | get stem) == nu) {
    error raise $"'($archive | path basename)' holds no nu binary" --kind not_found
  }
  $bins
}

# Run the extracted `nu` before anything is installed: it must report the build's version, and it must load this
# library as a login shell without config files (`--no-config-file --login`, the library root on the include
# path). The run imports the barrel (`use <root> *`) and then every module directory under the root (`use
# <root>/<name>` for each `<name>/mod.nu`, `_tests` included), since the barrel exposes only part of the library:
# every module parses, each module's `export-env` runs as a direct `use` runs it, and the barrel's login-gated
# loader (`conf`, which reads the machine override file) runs; the loaders gated on an interactive shell (`mods`,
# `proj`, `track`, `completion/local`) do not. A failure names the archive, which the caller leaves in the temp dir.
# nu-lint-ignore: external_script_as_argument
def smoke-test [
  binary: path # The extracted `nu`
  version: string # The version the build claims
  archive: path # The archive it came from
]: nothing -> nothing {
  log info $'smoke-testing ($binary)'
  let ran: record = try { ^$binary --no-config-file --commands 'version | get version' | complete } catch {|e|
    {exit_code: 1 stdout: '' stderr: $e.msg}
  }
  if $ran.exit_code != 0 {
    error raise $"the new nu does not run; its archive is kept at '($archive)'" --with={
      kind: external_failure
      help: ($ran.stderr | str trim)
    }
  }
  let reported: string = $ran.stdout | str trim
  if $reported != $version {
    error raise $"the new nu reports version '($reported)', not '($version)'" --with={
      kind: external_failure
      help: $"its archive is kept at '($archive)'"
    }
  }
  let modules: list<string> = glob ($ROOT | path join '*' mod.nu) | path dirname | each {|dir| $"use ($dir | to nuon)" }
  let program: string = [$"use ($ROOT | to nuon) *" ...$modules null] | str join '; '
  let loaded: record = try {
    ^$binary --no-config-file --login --include-path $ROOT --commands $program | complete
  } catch {|e| {exit_code: 1 stdout: '' stderr: $e.msg} }
  if $loaded.exit_code != 0 {
    let advice: string = [
      ($loaded.stderr | str trim)
      'fix the module for this nightly, or pass --no-smoke to install the build regardless'
    ] | compact --empty | str join (char newline)
    error raise $"nu ($version) cannot load this library; its archive is kept at '($archive)'" --with={
      kind: external_failure
      help: $advice
    }
  }
}

# Ask before installing; anything but `y`/`yes` aborts.
def confirm [build: record dir: path count: int]: nothing -> nothing {
  let answer: string = input $"install ($build.name) \(($count) binaries) into ($dir)? [y/N] "
  if ($answer | str trim | str lowercase) not-in [y yes] {
    error raise 'installation declined: nothing was installed' --kind invalid_argument
  }
}

# Copy files into `dir`, each written next to its destination and renamed over it, so that an existing file (the
# running `nu`, a running plugin) is replaced atomically, never rewritten in place. The replaced file is kept as
# `<name>.previous` (an older `.previous` is overwritten) for `--rollback`. A plugin that fails to install is a
# warning; `nu` failing is an error.
def install-files [dir: path]: list<path> -> list<path> {
  let files: list<path> = $in
  mkdir $dir
  $files | each {|file|
    let name: string = $file | path basename
    let dest: path = $dir | path join $name
    let stage: path = $dir | path join $'.($name).bump-nu'
    try {
      cp --force $file $stage
      if ($dest | path exists) {
        # Windows cannot replace a running executable, but it can rename it.
        if $nu.os-info.family == windows { mv --force $dest $'($dest).previous' } else { cp --force $dest $'($dest).previous' }
      }
      mv --force $stage $dest
      log info $'installed ($dest)'
      $dest
    } catch {|e|
      rm --force $stage
      if ($name | path parse | get stem) == nu { $e.raw } else { log warning $'could not install ($name): ($e.msg)' }
    }
  }
}

# ——— plugins ——————————————————————————————————————————————————————————————————

# The plugins of a registry file: none when it doesn't exist, or can't be read (a warning).
def registered-plugins [registry: path]: nothing -> table {
  if not ($registry | path exists) { return [] }
  try { plugin list --registry --plugin-config $registry | select name version filename } catch {|e|
    log warning $'could not read the plugin registry ($registry): ($e.msg)'
    []
  }
}

# Warn what installing does to the registered plugins: those shipped in the archive are updated; the others were
# built separately and may not load on the new version.
def warn-plugins [plugins: table shipped: list<string> version: string]: nothing -> nothing {
  let updated: list<string> = $plugins | where name in $shipped | get name
  let others: list<string> = $plugins | where name not-in $shipped | each { $'($in.name) ($in.version)' }
  if $updated != [] {
    log warning $'plugins shipped with ($version) are updated from the archive: ($updated | str join ", ")'
  }
  if $others != [] {
    log warning $'plugins built separately may fail to load on ($version); those that do are unregistered after installing, their binaries kept: ($others | str join ", ")'
  }
}

# Re-register the plugins of a registry with the new `nu` (see SYNC) and report each outcome. When the new `nu`
# cannot run the check, the plugins are reported as failed and left registered as they were.
# nu-lint-ignore: external_script_as_argument
def sync-plugins [
  binary: path # The newly installed `nu`
  registry: path
  plugins: table
  shipped: record
]: nothing -> table {
  if not ($registry | path exists) { return [] }
  let res: record = try {
    let job: string = {registry: $registry shipped: $shipped} | to nuon
    $job | ^$binary --no-config-file --stdin --commands $SYNC | complete
  } catch {|e| {exit_code: 1 stdout: '' stderr: $e.msg} }
  let rows: table = if $res.exit_code == 0 { try { $res.stdout | from nuon } } | default {
    let reason: string = $'the new nu could not check the plugins: ($res.stderr | str trim)'
    $plugins | each {|p| {name: $p.name filename: $p.filename action: failed message: $reason} }
  }
  for row in $rows {
    match $row.action {
      updated => { log info $'plugin ($row.name): updated from ($row.filename)' }
      kept => { log info $'plugin ($row.name): loads on the new nu' }
      removed => { log warning $'plugin ($row.name): unregistered, it fails to load on the new nu; its binary stays at ($row.filename): ($row.message)' }
      _ => { log warning $'plugin ($row.name): ($row.message)' }
    }
  }
  $rows
}

# ——— rollback —————————————————————————————————————————————————————————————————

# The name a `.previous` file is restored under: its basename without the suffix.
def restored-name []: path -> string { path basename | str replace --regex '\.previous$' '' }

# The `.previous` files a bump kept in `dir` (`nu.previous`, `nu_plugin_*.previous`), `nu` first.
def kept-previous [dir: path]: nothing -> list<path> {
  ls --all $dir | where type == file | get name
  | where ($it | path basename) =~ '^nu(_plugin_[^.]+)?(\.exe)?\.previous$'
  | sort-by {|file| ($file | restored-name | path parse | get stem) != nu }
}

# Put the previous build back: every `.previous` file of `dir` is installed over its current file the way a bump
# installs (staged, renamed over it), so the two swap — the build rolled back from becomes `.previous`. Returns
# `{installed plugins}`: the restored paths and the registry's plugins as they were, for `sync-plugins`.
def rollback [dir: path registry: path]: nothing -> record {
  if not ($dir | path join $'nu($EXE).previous' | path exists) {
    error raise $"there is no previous nu in '($dir)'" --with={
      kind: not_found
      help: 'only a bump keeps one, as `nu.previous` next to the installed `nu`'
    }
  }
  let kept: list<path> = kept-previous $dir
  let tmp: path = mktemp --directory --tmpdir bump-nu-XXXXXX
  try {
    let files: list<path> = $kept | each {|file|
      let staged: path = $tmp | path join ($file | restored-name)
      cp --force $file $staged
      $staged
    }
    let plugins: table = registered-plugins $registry
    let installed: list<path> = $files | install-files $dir
    rm --recursive --force $tmp
    {installed: $installed plugins: $plugins}
  } catch {|e|
    rm --recursive --force $tmp
    $e.raw
  }
}

# After files were installed: re-register the registry's plugins with the installed `nu` (`sync-plugins`), replace
# the shell with it when asked, and say when the running `nu` was replaced. Returns the plugin rows.
def finish [
  installed: list<path>
  plugins: table # The registry's plugins before installing
  registry: path
  version: string # The installed version, for the message
  --reload # Replace this shell with the installed `nu` (`reload --binary`)
]: nothing -> table {
  let nu_bin: path = $installed | where ($it | path parse | get stem) == nu | first
  let shipped: record = $installed | each {|file|
    let stem: string = $file | path parse | get stem
    if $stem starts-with nu_plugin_ { [($stem | str replace nu_plugin_ '') $file] }
  } | into record
  let rows: table = sync-plugins $nu_bin $registry $plugins $shipped
  if $reload { reload --binary $nu_bin }
  if ($nu_bin | path expand) == ($nu.current-exe | path expand) {
    log info $'replaced the running nu: new shells, or `reload`, run ($version)'
  }
  $rows
}

# ——— commands —————————————————————————————————————————————————————————————————

# Install the latest Nushell nightly build.
#
# Reads the newest release from the releases API (`--source`; `GITHUB_TOKEN`, when set, is sent to GitHub's API
# only) and picks this host's build. The current version is that of the `nu` installed in the install directory
# (`nu --version`; null when there is none or it does not run), not the running one: a stable build another tool
# wrote over the nightly is detected even while the nightly is still running. When the build is the current version
# it says so and stops before downloading; `--check` stops there in any case. Otherwise it downloads the archive,
# verifies its published sha256 (the asset's `digest`, else the release's `SHA256SUMS`; skipped only when the
# release publishes neither — a `SHA256SUMS` that does not list the archive refuses the build like a mismatch),
# extracts `nu` and the `nu_plugin_*` binaries and smoke-tests the new `nu` from the temp dir: it must report the
# build's version and load this library as a login shell without config files (`--no-config-file --login`, the
# library root on the include path): the barrel and then every module directory under the root (`<name>/mod.nu`,
# those the barrel does not expose included), which runs `conf`'s loader against the machine override file but
# not the interactive-only loaders. A build that fails is refused before anything changes; its archive is kept in
# the temp dir, which the error names. `--no-smoke` skips the test, for a nu that cannot load this library (a
# module to fix).
# Then it asks for confirmation (`--yes` skips it; without a terminal it is required, and checked before anything
# is fetched) and copies the files into the install directory. Each file is written next to its destination and
# renamed over it, so the running `nu` and running plugins are replaced atomically, and the replaced file is kept
# as `<name>.previous` (`nu.previous`, `nu_plugin_<x>.previous`; an older one is overwritten). The running shell
# keeps the old binary until `--reload` or a new shell.
#
# `--rollback` puts the previous build back: `nu.previous` and every `nu_plugin_*.previous` of the install
# directory are installed over the current files the same way, so the two builds swap (the one rolled back from is
# now `.previous`), and the registry's plugins are re-registered with the restored `nu`. Nothing is fetched. It
# errors when there is no `nu.previous`. A plugin the bump unregistered is not re-added (its binary was kept: `plugin
# add` it), and one installed without a previous copy stays.
#
# Plugin problems never abort a bump and plugin binaries are never deleted. Before installing, the registered
# plugins are listed as warnings: those shipped in the archive are updated, the others may fail to load on the new
# version. After installing, the new `nu` re-registers every plugin of the registry (`--plugin-config`), a shipped
# one from its installed copy, and unregisters (`plugin rm`) each one that fails to load. The archive's plugins that
# were not registered are installed but stay unregistered.
#
# Returns `{current latest up_to_date asset}`, plus (unless `--check`) `installed` (the installed paths) and
# `plugins` (`{name filename action message}` per registered plugin, `action` one of `updated`, `kept`,
# `removed`, `failed`); `--check` adds `previous`, the version of `nu.previous` (null without one). `--rollback`
# returns `{current previous installed plugins}`: the versions now installed and kept, the restored paths and the
# plugin rows.
@category system
export def bump-nu [
  --install-dir (-d): path # Where to install `nu` and the archive's plugins (default: the running `nu`'s directory)
  --check (-c) # Only compare the installed version with the latest nightly; download and install nothing
  --yes (-y) # Install without asking for confirmation (required without a terminal)
  --interactive (-i) # Choose the build from the release's archives instead of this host's
  --musl # Install the statically linked musl build (Linux only)
  --no-smoke # Install without smoke-testing the new `nu` (for a nu that cannot load this library)
  --rollback # Put the previous build (`nu.previous` and the plugins' `.previous`) back instead of installing
  --reload (-r) # After installing, replace this shell with the installed `nu` (`reload --binary`)
  --source: string = $SOURCE # The releases API to read (GitHub's JSON shape)
  --plugin-config: path # The plugin registry file to update (default: `$nu.plugin-path`)
]: nothing -> record {
  let tty: bool = is-terminal --stdin
  if $rollback and ($check or $interactive or $musl or $no_smoke) {
    error raise '--rollback is exclusive with --check, --interactive, --musl and --no-smoke' --with={
      kind: invalid_argument
      help: '--rollback installs nothing new'
    }
  }
  if $interactive and not $tty {
    error raise '--interactive needs a terminal' --kind unsupported
  }
  if not ($check or $rollback or $yes or $tty) {
    error raise 'there is no terminal to confirm the installation' --with={
      kind: unsupported
      help: 'pass --yes to install without confirmation, or --check to only compare versions'
    }
  }
  let dir: path = install-dir $install_dir --writable=(not $check)
  let registry: path = $plugin_config | default $nu.plugin-path
  if $rollback {
    let done: record = rollback $dir $registry
    let current: oneof<string, nothing> = binary-version ($dir | path join $'nu($EXE)')
    let rows: table = finish $done.installed $done.plugins $registry ($current | default 'the previous build') --reload=$reload
    return {
      current: $current
      previous: (binary-version ($dir | path join $'nu($EXE).previous'))
      installed: $done.installed
      plugins: $rows
    }
  }

  let target: oneof<string, nothing> = if not $interactive { host-target $nu.os-info --musl=$musl }
  let release: record = latest-release $source
  let build: record = pick-build ($release.assets | parse-assets) $target
  let current: oneof<string, nothing> = binary-version ($dir | path join $'nu($EXE)')
  let summary: record = {
    current: $current
    latest: $build.version
    up_to_date: ($build.version == $current)
    asset: $build.name
  }
  if $check { return ($summary | insert previous (binary-version ($dir | path join $'nu($EXE).previous'))) }
  if $summary.up_to_date {
    log info $'nu ($current) is already the latest nightly'
    return ($summary | insert installed [] | insert plugins [])
  }

  let tmp: path = mktemp --directory --tmpdir bump-nu-XXXXXX
  let staged: record = try {
    let sums: oneof<record, nothing> = $release.assets | where name == SHA256SUMS | get 0?
    let archive: path = download $build $sums $tmp
    {archive: $archive files: (extract $archive ($tmp | path join extract))}
  } catch {|e|
    rm --recursive --force $tmp
    $e.raw
  }
  # A refused build keeps the temp dir: the error names the archive.
  if not $no_smoke { smoke-test ($staged.files | first) $build.version $staged.archive }
  let done: record = try {
    let plugins: table = registered-plugins $registry
    let names: list<string> = $staged.files | path parse | get stem | where $it starts-with nu_plugin_ | str replace nu_plugin_ ''
    warn-plugins $plugins $names $build.version
    if not $yes { confirm $build $dir ($staged.files | length) }
    let installed: list<path> = $staged.files | install-files $dir
    rm --recursive --force $tmp
    {installed: $installed plugins: $plugins}
  } catch {|e|
    rm --recursive --force $tmp
    $e.raw
  }
  $summary
  | insert installed $done.installed
  | insert plugins (finish $done.installed $done.plugins $registry $build.version --reload=$reload)
}
