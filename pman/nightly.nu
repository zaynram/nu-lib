# Install the latest Nushell nightly build: `pman bump-nu`.
#
# Adopted from the owner's `nightly-toolkit` module (a rewrite of nupm's nightly toolkit). `pman` re-exports only
# `bump-nu`; the other exports are helpers that the pman suite tests directly.

# ——— imports ——————————————————————————————————————————————————————————————————

use std/log
use error
use reload

# ——— constants ————————————————————————————————————————————————————————————————

# The releases API of the nightly repository.
export const SOURCE: string = 'https://api.github.com/repos/nushell/nightly/releases'

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
    _ if $musl => (error raise $"--musl builds exist only for Linux, not '($os.name)'" --kind unsupported)
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

# The install directory: `dir`, or the running `nu`'s directory. Outside the home directory it needs elevated
# privileges.
def install-dir [dir?: path]: nothing -> path {
  let dir: path = $dir | default ($nu.current-exe | path dirname) | path expand --no-symlink
  if not ($dir | is-under $nu.home-dir) and not (is-admin) {
    error raise $"installing into '($dir)' needs elevated privileges" --kind unsupported --advice 'rerun elevated, or pass an --install-dir inside your home directory'
  }
  $dir
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
    $archives | input list --display target $'(ansi cyan)Choose a build(ansi reset)'
    | default { error raise 'no build chosen: nothing was installed' --kind invalid_argument }
  } else {
    let ext: string = if $target =~ windows { 'zip' } else { 'tar.gz' }
    $archives | where {|b| $b.target == $target and $b.ext == $ext } | get 0? | default {
      let known: string = $archives | each { get target } | str join ', '
      error raise $"the latest release has no build for '($target)'" --kind not_found --advice $'builds: ($known); choose one with --interactive'
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
      http get --raw $asset.browser_download_url | collect | if ($in | describe) == binary { decode } else { }
      | lines | parse --regex '^(?<hash>[0-9a-fA-F]{64}) [ *](?<file>.+)$'
      | where file == $build.name | get 0?.hash | each { str lowercase }
    }
  }
}

# Download a build into `dir` and check it against its published sha256 (skipped when none is published).
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
  if $expected != null {
    let actual: string = open --raw $archive | hash sha256
    if $actual != $expected {
      error raise $"'($build.name)' does not match its published sha256" --kind io --advice $'expected ($expected), got ($actual)'
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
    error raise $"could not extract '($archive | path basename)'" --kind external_failure --advice ($res.stderr | str trim)
  }
  let bins: list<path> = do { cd $dir; glob '**/*' --no-dir } | where {|file|
    let parts: record = $file | path parse
    $parts.extension in ['' exe] and ($parts.stem == nu or ($parts.stem | str starts-with nu_plugin_))
  } | sort-by {|file| ($file | path parse | get stem) != nu }
  if not ($bins | any {|file| ($file | path parse | get stem) == nu }) {
    error raise $"'($archive | path basename)' holds no nu binary" --kind not_found
  }
  $bins
}

# Ask before installing; anything but `y`/`yes` aborts.
def confirm [build: record dir: path count: int]: nothing -> nothing {
  let answer: string = input $"install ($build.name) \(($count) binaries) into ($dir)? [y/N] "
  if ($answer | str trim | str lowercase) not-in [y yes] {
    error raise 'installation declined: nothing was installed' --kind invalid_argument
  }
}

# Copy files into `dir`, each written next to its destination and renamed over it, so that an existing file (the
# running `nu`, a running plugin) is replaced atomically, never rewritten in place. A plugin that fails to install
# is a warning; `nu` failing is an error.
def install-files [dir: path]: list<path> -> list<path> {
  let files: list<path> = $in
  mkdir $dir
  $files | each {|file|
    let name: string = $file | path basename
    let dest: path = $dir | path join $name
    let stage: path = $dir | path join $'.($name).bump-nu'
    try {
      cp --force $file $stage
      # Windows cannot replace a running executable, but it can rename it.
      if $nu.os-info.family == windows and ($dest | path exists) { mv --force $dest $'($dest).old' }
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

# ——— commands —————————————————————————————————————————————————————————————————

# Install the latest Nushell nightly build.
#
# Reads the newest release from the releases API (`--source`; `GITHUB_TOKEN`, when set, is sent to GitHub's API
# only) and picks this host's build. When that is the running version (`(version).version`) it says so and stops
# before downloading; `--check` stops there in any case. Otherwise it downloads the archive, verifies its published
# sha256 (the asset's `digest`, else the release's `SHA256SUMS`; skipped when the release publishes neither),
# extracts `nu` and the `nu_plugin_*` binaries, asks for confirmation (`--yes` skips it; without a terminal it is
# required, and checked before anything is fetched) and copies them into the install directory. Each file is
# written next to its destination and renamed over it, so the running `nu` and running plugins are replaced
# atomically; the running shell keeps the old binary until `--reload` or a new shell.
#
# Plugin problems never abort the bump and plugin binaries are never deleted. Before installing, the registered
# plugins are listed as warnings: those shipped in the archive are updated, the others may fail to load on the new
# version. After installing, the new `nu` re-registers every plugin of the registry (`--plugin-config`), a shipped
# one from its installed copy, and unregisters (`plugin rm`) each one that fails to load. The archive's plugins that
# were not registered are installed but stay unregistered.
#
# Returns `{current latest up_to_date asset}`, plus (unless `--check`) `installed` (the installed paths) and
# `plugins` (`{name filename action message}` per registered plugin, `action` one of `updated`, `kept`,
# `removed`, `failed`).
@category system
export def bump-nu [
  --install-dir (-d): path # Where to install `nu` and the archive's plugins (default: the running `nu`'s directory)
  --check (-c) # Only compare the running version with the latest nightly; download and install nothing
  --yes (-y) # Install without asking for confirmation (required without a terminal)
  --interactive (-i) # Choose the build from the release's archives instead of this host's
  --musl # Install the statically linked musl build (Linux only)
  --reload (-r) # After installing, replace this shell with the installed `nu` (`reload --binary`)
  --source: string = $SOURCE # The releases API to read (GitHub's JSON shape)
  --plugin-config: path # The plugin registry file to update (default: `$nu.plugin-path`)
]: nothing -> record {
  let tty: bool = is-terminal --stdin
  if $interactive and not $tty {
    error raise '--interactive needs a terminal' --kind unsupported
  }
  if not ($check or $yes or $tty) {
    error raise 'there is no terminal to confirm the installation' --kind unsupported --advice 'pass --yes to install without confirmation, or --check to only compare versions'
  }
  let target: oneof<string, nothing> = if not $interactive { host-target $nu.os-info --musl=$musl }
  let dir: oneof<path, nothing> = if not $check { install-dir $install_dir }
  let release: record = latest-release $source
  let build: record = pick-build ($release.assets | parse-assets) $target
  let current: string = (version).version
  let summary: record = {
    current: $current
    latest: $build.version
    up_to_date: ($build.version == $current)
    asset: $build.name
  }
  if $check { return $summary }
  if $summary.up_to_date {
    log info $'nu ($current) is already the latest nightly'
    return ($summary | insert installed [] | insert plugins [])
  }

  let registry: path = $plugin_config | default $nu.plugin-path
  let tmp: path = mktemp --directory --tmpdir bump-nu-XXXXXX
  let done: record = try {
    let sums: oneof<record, nothing> = $release.assets | where name == SHA256SUMS | get 0?
    let archive: path = download $build $sums $tmp
    let files: list<path> = extract $archive ($tmp | path join extract)
    let plugins: table = registered-plugins $registry
    let names: list<string> = $files | path parse | get stem | where $it starts-with nu_plugin_ | str replace nu_plugin_ ''
    warn-plugins $plugins $names $build.version
    if not $yes { confirm $build $dir ($files | length) }
    let installed: list<path> = $files | install-files $dir
    rm --recursive --force $tmp
    {installed: $installed plugins: $plugins}
  } catch {|e|
    rm --recursive --force $tmp
    $e.raw
  }

  let nu_bin: path = $done.installed | where {|file| ($file | path parse | get stem) == nu } | first
  let shipped: record = $done.installed | each {|file|
    let stem: string = $file | path parse | get stem
    if $stem starts-with nu_plugin_ { [($stem | str replace nu_plugin_ '') $file] }
  } | into record
  let result: record = $summary
    | insert installed $done.installed
    | insert plugins (sync-plugins $nu_bin $registry $done.plugins $shipped)
  if $reload { reload --binary $nu_bin }
  if ($nu_bin | path expand) == ($nu.current-exe | path expand) {
    log info $'replaced the running nu: new shells, or `reload`, run ($build.version)'
  }
  $result
}
