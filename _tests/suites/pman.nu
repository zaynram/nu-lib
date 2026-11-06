# `pman`: `test _tests/suites/pman.nu`.
#
# pman runs package managers, `sudo` and plugin commands. Nothing real is ever run here:
# - `install`/`remove`/`clean`/`apt` run in sandboxed children with stub `sudo`/`apt-get` first on PATH.
# - `upgrade` first puts `machine-config user`'s binary directories on PATH, and the first one is the directory of
#   the running `nu` (which, on the owner's machine, also holds the real `rustup`/`cargo`). It therefore runs in a
#   grandchild started from a *copy* of the `nu` binary inside the sandbox, with stubs for every registry binary
#   in the sandbox `~/.local/bin`; the grandchild refuses to run if any binary directory is outside the sandbox, and
#   `http get` is shadowed there to serve the fixture release, so `upgrade`'s auto-bump never reaches the network.
# - `reload-plugins` runs with the `plugin` commands and `cargo` shadowed by definitions made before `use pman`.
# - `bump-nu` runs in a grandchild started from a copy of `nu` in the sandbox (so `$nu.current-exe`, and with it the
#   default install directory, is in the sandbox) against fixture releases served by a localhost HTTP server
#   (`--source`), with a sandbox plugin registry (`--plugin-config`); see the bump-nu section.
# nu-lint-ignore-file: missing_output_type
# (helpers return whatever the child produced)
use pman
use pman/nightly.nu
use ../mod.nu *

const REGISTRY_BINS: list<string> = [rustup dprint brew claude cargo pipx pixi bun]

# ——— helpers ——————————————————————————————————————————————————————————————————

# Replace every `@PLACEHOLDER@` key of `values` in a template with its value.
def fill-in [values: record]: string -> string {
  let template: string = $in
  $values | transpose key value | reduce --fold $template {|it acc| $acc | str replace --all $it.key $it.value }
}

# Write an executable stub that appends `<name> <args>` to `log` and echoes it (or fails, with `--fail`), then runs
# the shell lines of `--also`.
def stub [dir: path name: path log: path --fail --also: string = '']: nothing -> nothing {
  need-posix
  mkdir $dir
  let body: string = if $fail {
    $'echo "($name) failed: $*" >&2(char newline)exit 3'
  } else {
    $'echo "($name) $*" >> "($log)"(char newline)echo "($name) $*"'
  }
  [$"#!/bin/sh\n($body)" $also] | compact --empty | str join (char newline) | $in + (char newline)
  | save --force ($dir | path join $name)
  ^chmod +x ($dir | path join $name)
}

# Run `code` after `use pman` in a sandboxed child with `sudo`/`apt-get` stubs first on PATH.
def with-sudo [ctx: record code: string]: nothing -> record {
  let bin: path = $ctx.code | path join stubs
  let log: path = $ctx.code | path join calls.log
  stub $bin sudo $log
  stub $bin apt-get $log
  let res: record = sandboxed $ctx $code --prelude 'use pman' --vars {PATH: ([$bin /usr/bin /bin] | str join (char esep))}
  let calls: list<string> = if ($log | path exists) { open --raw $log | lines } else { [] }
  $res | insert calls $calls
}

# The prelude of an `upgrade` grandchild: it refuses to run with a binary directory outside the sandbox, and it
# shadows `http get` (seen by `pman` because it is defined first) to serve `@WWW@`, the fixture release a test wrote
# with `release`, so `bump-nu` can never reach the network from an upgrade. The releases API `bump-nu` reads by
# default is the fixture's `releases.json`; any other URL names a file under `@WWW@`, and a missing one fails like a
# 404.
const UPGRADE_GUARD: string = r#'
use conf/machine.nu [ machine-config ]
let outside = (machine-config user).binaries | where not ($it starts-with $env.HOME) and not ($it starts-with $env.SBPMAN_NUBIN)
if $outside != [] { error make --unspanned {msg: $"refusing to run: binaries outside the sandbox: ($outside)"} }
def "http get" [url: string --headers: record = {} --raw] {
  let file = if $url == 'https://api.github.com/repos/nushell/nightly/releases' {
    '@WWW@/releases.json'
  } else {
    $url | str replace --regex '^https?://[^/]+/' '@WWW@/'
  }
  if not ($file | path exists) { error make --unspanned {msg: $"sbfixture: ($url) is not served"} }
  if $raw { open --raw $file } else { open $file }
}
use pman
'#

# The `nu` that `cargo install-update --all` leaves behind: a stable build, `--version` prints 0.100.0.
const STABLE_NU: string = r##'#!/bin/sh
case " $* " in *" --version "*) echo 0.100.0; exit 0 ;; esac
exit 0
'##

# Run `code` with `pman` in a grandchild started from a copy of `nu` in the sandbox, with stubs for every
# registry binary (and `sudo`/`apt-get`) in the sandbox `~/.local/bin`. `failing` stubs exit non-zero. With
# `--clobber-nu`, the `cargo` stub also renames a stable `nu` (`STABLE_NU`) over the sandbox `nu`, as
# `cargo install-update --all` does on the owner's machine.
def stubbed-upgrade [ctx: record code: string --failing: list<string> = [] --clobber-nu]: nothing -> record {
  let nubin: path = $ctx.code | path join nubin
  mkdir $nubin
  cp $nu.current-exe ($nubin | path join nu)
  let local: path = $ctx.home | path join .local bin
  let log: path = $ctx.code | path join calls.log
  for name in ($REGISTRY_BINS ++ [sudo apt-get]) { stub $local $name $log --fail=($name in $failing) }
  if $clobber_nu {
    let stable: path = $ctx.code | path join stable-nu
    $STABLE_NU | save --force $stable
    ^chmod +x $stable
    stub $local cargo $log --also $"mv -f ($stable | to nuon) ($nubin | path join nu | to nuon)"
  }
  let guard: string = $UPGRADE_GUARD | fill-in {'@WWW@': ($ctx.code | path join www)}
  let vars: record = {
    HOME: $ctx.home
    XDG_CONFIG_HOME: $ctx.config
    XDG_DATA_HOME: $ctx.data
    XDG_CACHE_HOME: $ctx.cache
    XDG_STATE_HOME: $ctx.state
    TMPDIR: ($ctx.root | path join tmp)
    PATH: ([/usr/bin /bin] | str join (char esep))
    SBPMAN_NUBIN: $nubin
  }
  mkdir $vars.TMPDIR
  let program: string = $"($guard)\n($code) | to nuon --serialize"
  let res: record = with-env $vars {
    ^($nubin | path join nu) --no-config-file --include-path=($ROOT) --commands $program | complete
  }
  if $res.exit_code != 0 { error make --unspanned {msg: $"upgrade child failed: ($res.stderr | str trim)"} }
  let calls: list<string> = if ($log | path exists) { open --raw $log | lines } else { [] }
  {value: ($res.stdout | from nuon) calls: $calls stderr: $res.stderr log: ($ctx.cache | path join nushell update_results.nuon)}
}

# ——— constants and re-exports —————————————————————————————————————————————————

def "test registry lists the upgrade commands" []: nothing -> nothing {
  assert equal ($pman.REGISTRY | columns) $REGISTRY_BINS 'the managed binaries'
  assert ($pman.REGISTRY | values | all ($it | describe) =~ '^list<list') 'each entry is a list of argument sets'
}

def "test log lives in the cache dir" []: nothing -> nothing {
  assert equal $pman.LOG.upgrade ($nu.cache-dir | path join update_results.nuon) 'the upgrade log path'
}

def "test bump nu is exported" []: nothing -> nothing {
  let names: list<string> = scope commands | get name | where $it starts-with 'pman '
  assert ('pman bump-nu' in $names) 'the nightly installer'
  assert not ($names | any $it =~ 'nightly') "the submodule's helpers stay private"
}

# ——— history ——————————————————————————————————————————————————————————————————

def "test history rejects an unknown target" []: nothing -> nothing {
  let err: record = try { pman history nope; {} } catch {|e| $e }
  assert equal $err.details?.code? pman::history::invalid_argument 'only LOG targets'
  assert ($err.details?.help? =~ 'upgrade') $'the advice lists the targets: ($err.details?.help?)'
}

def "test history of a missing log" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = sandboxed $ctx '{log: (pman history upgrade) age: (pman history upgrade --age)} | to nuon' --prelude 'use pman' --pipe
    assert equal $r {log: null age: null} 'a missing log is null'
    let res: record = sandboxed $ctx 'pman history upgrade --throw' --prelude 'use pman'
    assert ($res.exit_code != 0 and $res.stderr =~ 'no cached results found') $'--throw raises: ($res.stderr)'
    assert ($res.stderr =~ 'pman::history::not_found') $'the not_found code: ($res.stderr)'
  }
}

def "test history reads the saved log" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = 'mkdir $nu.cache-dir; {x: [{output: o success: true}]} | save $pman.LOG.upgrade
      {log: (pman history upgrade) age: (pman history upgrade --age | describe)} | to nuon'
    let r: record = sandboxed $ctx $code --prelude 'use pman' --pipe
    assert equal $r.log {x: [{output: o success: true}]} 'the parsed results'
    assert equal $r.age duration '--age is the time since the last write'
  }
}

# ——— apt wrappers —————————————————————————————————————————————————————————————

def "test install runs apt get install through sudo" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = with-sudo $ctx 'pman install sbpkg-a sbpkg-b'
    assert equal $res.calls ['sudo apt-get install --yes sbpkg-a sbpkg-b'] 'one sudo call'
  }
}

def "test install without packages raises" []: nothing -> nothing {
  let err: record = try { pman install; {} } catch {|e| $e }
  assert equal $err.details?.code? pman::install::invalid_argument 'no packages is an error'
}

def "test remove removes then cleans" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = with-sudo $ctx 'pman remove sbpkg'
    assert equal $res.calls [
      'sudo apt-get remove --yes sbpkg'
      'sudo apt-get autoremove --yes'
      'sudo apt-get autoclean --yes'
    ] 'remove, autoremove, autoclean'
  }
}

def "test remove without packages only cleans" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = with-sudo $ctx 'pman remove'
    assert equal $res.calls ['sudo apt-get autoremove --yes' 'sudo apt-get autoclean --yes'] 'just the clean-up'
  }
}

def "test apt passes arguments through" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = with-sudo $ctx 'pman apt list --installed -q'
    assert equal $res.calls ['sudo apt-get list --installed -q'] 'flags pass through'
  }
}

# ——— upgrade ——————————————————————————————————————————————————————————————————

def "test upgrade async with system raises" []: nothing -> nothing {
  let err: record = try { pman upgrade --async --system; {} } catch {|e| $e }
  assert equal $err.details?.code? pman::upgrade::invalid_argument 'sudo needs a prompt'
  assert ($err.details?.help? =~ 'foreground') $'the advice says what to do: ($err.details?.help?)'
}

def "test upgrade runs every registry entry" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx 'pman upgrade'
    assert equal ($r.value | columns) $REGISTRY_BINS 'one result per binary'
    assert equal $r.value.rustup [{output: "rustup upgrade\n" success: true}] 'stdout of a successful call'
    assert equal ($r.value.pixi | get output) ["pixi self-update\n" "pixi global update\n"] 'argument sets run in order'
    assert equal ($r.calls | where $it starts-with bun) ['bun upgrade --canary' 'bun --global update'] 'every set runs, one after another, in order'
    assert not ($r.calls | any $it starts-with 'sudo') 'no system packages without --system'
  }
}

def "test upgrade reports failures with stderr" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx 'pman upgrade' --failing [dprint]
    assert equal $r.value.dprint [{output: "dprint failed: upgrade\n" success: false}] 'stderr of a failed call'
    assert equal ($r.value.brew | get success) [true] 'other binaries are unaffected'
  }
}

def "test upgrade saves the results" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx '{returned: (pman upgrade) saved: (pman history upgrade)}'
    assert equal $r.value.saved $r.value.returned 'the log holds the returned record'
  }
}

def "test upgrade silent returns nothing" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx '{returned: (pman upgrade --silent) saved: (pman history upgrade | columns)}'
    assert equal $r.value.returned null '--silent returns nothing'
    assert equal $r.value.saved $REGISTRY_BINS 'but still saves the results'
  }
}

def "test upgrade input overrides the registry" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx '{rustup: [[sbcustom --flag]] dprint: "bad" sbpman_missing: [[x]]} | pman upgrade'
    assert equal $r.value.rustup.0.output "rustup sbcustom --flag\n" 'piped arguments replace the registry entry'
    let dprint: record = $r.value.dprint | first
    assert ($dprint.output starts-with 'invalid arguments') 'a malformed entry is reported'
    assert equal $dprint.success false 'and failed'
    assert equal $r.value.sbpman_missing [{output: "command not found: 'sbpman_missing'" success: false}] 'a missing binary is reported'
    assert not ($r.calls | any $it starts-with 'dprint') 'the overridden entry does not run'
  }
}

def "test upgrade system runs apt get through sudo" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx 'pman upgrade --system'
    assert equal ($r.value.apt-get | get output) ["sudo apt-get update --yes\n" "sudo apt-get upgrade --yes\n"] 'update then upgrade'
    assert equal ($r.calls | where $it starts-with 'sudo apt-get') ['sudo apt-get update --yes' 'sudo apt-get upgrade --yes'] "upgrade runs only after update (they share apt's lock)"
  }
}

def "test upgrade async returns the job" []: nothing -> nothing {
  with-sandbox {|ctx|
    # A fresh log makes the job a no-op (it only upgrades when the log is over a day old).
    let code: string = 'mkdir $nu.cache-dir; {} | save $pman.LOG.upgrade; pman upgrade --async | select description'
    let r: record = stubbed-upgrade $ctx $code
    assert equal $r.value {description: pkg-auto-upgrade} 'the background job record'
  }
}

# ——— reload-plugins ———————————————————————————————————————————————————————————

# Shadow the plugin commands (definitions made before `use pman` are seen by it) and `cargo`. `plugin list` takes
# the flags `bump-nu` passes it, so that pman still parses.
const PLUGIN_STUBS: string = '
def "plugin list" [--registry --plugin-config: path] { [[name filename version]; [sbbroken /x/nu_plugin_sbbroken 0.1] [sbgood /x/nu_plugin_sbgood 0.2]] }
def "plugin stop" [name: string] { print $"STOP ($name)" }
def "plugin rm" [name: string] { print $"RM ($name)" }
def "plugin add" [file: path] { if $file =~ broken { error make --unspanned {msg: boom} } else { print $"ADD ($file)" } }
def cargo [...args] { print $"CARGO ($args | str join (char space))" }
use pman
'

def "test reload plugins re-adds every plugin" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = sandboxed $ctx 'pman reload-plugins' --prelude $PLUGIN_STUBS
    assert equal $res.exit_code 0 'a failed re-add does not abort'
    let out: list<string> = $res.stdout | lines | ansi strip
    assert equal ($out | where $it starts-with ADD) ['ADD /x/nu_plugin_sbgood'] 'working plugins are re-added'
    assert equal ($out | where $it starts-with STOP) ['STOP sbbroken' 'STOP sbgood'] 'every plugin is stopped first'
  }
}

def "test reload plugins never uninstalls a failing plugin" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = sandboxed $ctx 'pman reload-plugins' --prelude $PLUGIN_STUBS
    assert not ($res.stdout =~ 'CARGO') 'cargo is never called'
    assert ($res.stderr =~ 'could not re-add sbbroken') $'the failure is reported: ($res.stderr)'
  }
}

def "test reload plugins filters by name" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = sandboxed $ctx 'pman reload-plugins sbgood' --prelude $PLUGIN_STUBS
    assert equal ($res.stdout | lines | where $it starts-with STOP) ['STOP sbgood'] 'only the named plugin'
  }
}

# ——— bump-nu ——————————————————————————————————————————————————————————————————
#
# Pure helpers are tested directly through `pman/nightly.nu`. `bump-nu` itself runs in a grandchild (`run-bump`)
# started from a sandbox copy of `nu`, against a release (`release`) served from the sandbox by a localhost HTTP
# server (`with-server`), installing into the sandbox and updating a sandbox plugin registry. The archives hold a
# stub `nu` (it logs its first two arguments, answers `--version` and `version | get version` with the build's
# version, hands other `--commands` runs to the real `nu`, and otherwise exits) and stub plugins that speak just
# enough of the plugin protocol for `plugin add`. Prompts are answered through a pseudo-terminal (`run-bump --pty`).

const NEWER: string = '0.999.0-nightly.1'
const OLDER: string = '0.998.0-nightly.1'

# The `nu` of the fixture archives (see the section comment); `stub-nu` fills in @LOG@, @NU@ and @VERSION@. The
# program of a `--login` run (its sixth argument) is kept in `@LOG@.login`.
const STUB_NU: string = r##'#!/bin/sh
printf 'run:%s\n' "$1${2:+ $2}" >> '@LOG@'
case " $* " in *" --login "*) printf '%s' "$6" > '@LOG@.login' ;; esac
case " $* " in
  *" --version "*|*" version | get version "*) echo '@VERSION@'; exit 0 ;;
  *" --commands "*) exec '@NU@' "$@" ;;
esac
exit 0
'##

# A `nu` that reports its version and fails every other run (it cannot load the library).
const VERSION_ONLY_NU: string = r##'#!/bin/sh
case " $* " in *" --version "*|*" version | get version "*) echo '@VERSION@'; exit 0 ;; esac
echo 'sbstub: cannot load' >&2
exit 1
'##

# A `nu` that fails every run.
const BROKEN_NU: string = "#!/bin/sh\necho 'sbstub: broken' >&2\nexit 1\n"

# A `nu` that reports its version and hands other `--commands` runs to the real `nu`, but fails as a login shell:
# the barrel's login-gated loader (`conf`) does not come up on it.
const LOGIN_FAILING_NU: string = r##'#!/bin/sh
case " $* " in
  *" --version "*|*" version | get version "*) echo '@VERSION@'; exit 0 ;;
  *" --login "*) echo 'sbstub: the conf loader fails' >&2; exit 1 ;;
  *" --commands "*) exec '@NU@' "$@" ;;
esac
exit 0
'##

# Write a stub `nu` (`STUB_NU` unless another template is given) of `version` to `file`, logging to
# `$ctx.code/nu.log`.
def stub-nu [ctx: record file: path version: string --template: string = $STUB_NU]: nothing -> nothing {
  need-posix
  mkdir ($file | path dirname)
  $template | fill-in {'@LOG@': ($ctx.code | path join nu.log) '@NU@': $nu.current-exe '@VERSION@': $version} | save --force $file
  ^chmod +x $file
}

# Runs `pman bump-nu` in the grandchild and saves `{value}` or `{error code help rendered}` as nuon (stdout may be a
# terminal).
const BUMP: string = r#'use pman
let r = try { {value: (pman bump-nu @FLAGS@)} } catch {|e|
  {error: $e.msg code: ($e.details?.code? | default "") help: ($e.details?.help? | default "") rendered: ($e.rendered | ansi strip)}
}
$r | to nuon | save --force @OUT@'#

# Where the tests install, and the sandbox plugin registry.
def bin-dir []: record -> path { get home | path join bin }
def registry []: record -> path { get root | path join plugins.msgpackz }

# The flags pointing `bump-nu` at the fixture server, the sandbox install directory and the sandbox registry.
def flags [ctx: record url: string]: nothing -> string {
  [
    --source ($'($url)/releases.json' | to nuon)
    --install-dir ($ctx | bin-dir | to nuon)
    --plugin-config ($ctx | registry | to nuon)
  ] | str join ' '
}

# Write an executable stub plugin built for nushell `version`, of its own version `--plugin-version` (see the fixture).
def stub-plugin [file: path version: string --plugin-version: string = '0.1.0']: nothing -> nothing {
  need-posix
  mkdir ($file | path dirname)
  open --raw ($FIXTURES | path join pman nu_plugin_stub.sh)
  | fill-in {'@VERSION@': $version '@PLUGIN_VERSION@': $plugin_version}
  | save --force $file
  ^chmod +x $file
}

# Register stub plugins built for the running `nu` in the sandbox registry: `{<name>: <dir>}` adds
# `<dir>/nu_plugin_<name>`.
def register [ctx: record plugins: record]: nothing -> nothing {
  $plugins | items {|name dir|
    let file: path = $dir | path join $'nu_plugin_($name)'
    stub-plugin $file (version).version
    plugin add --plugin-config ($ctx | registry) $file
  } | ignore
}

# The sandbox registry as `{<name>: <filename>}`.
def registered [ctx: record]: nothing -> record {
  plugin list --registry --plugin-config ($ctx | registry) | each {|p| [$p.name $p.filename] } | into record
}

# The sandbox registry as `{<name>: <plugin version>}`.
def plugin-versions [ctx: record]: nothing -> record {
  plugin list --registry --plugin-config ($ctx | registry) | each {|p| [$p.name $p.version] } | into record
}

# Write a release fixture into `$ctx.code/www`: `releases.json` lists an older release first, then the release of
# `version` with one `.tar.gz` per target (a stub `nu`, the stub `plugins` of `--plugin-version`, LICENSE and
# README.txt) and an `.msi`. `--digest`/`--sums` (`ok`, `bad`, `none`) set the archives' `digest` and a `SHA256SUMS`
# asset; `--sums missing` lists the asset without serving it, `--sums unlisted` serves one that names other files only.
def release [
  ctx: record
  url: string
  version: string
  --targets: list<string> = []
  --plugins: list<string> = []
  --plugin-version: string = '0.1.0'
  --nu-version: string = '' # The version the archives' `nu` reports, when not `version`
  --digest: string = ok
  --sums: string = none
  --broken-nu # The archives' `nu` fails every run
  --version-only-nu # The archives' `nu` reports its version but fails every other run
  --login-failing-nu # The archives' `nu` fails as a login shell (where `conf`'s loader runs)
  --without-nu # The archives hold no `nu`
]: nothing -> nothing {
  need-posix # the stubs, and `tar`
  let www: path = $ctx.code | path join www
  mkdir $www
  let template: string = if $broken_nu { $BROKEN_NU } else if $version_only_nu { $VERSION_ONLY_NU } else if $login_failing_nu { $LOGIN_FAILING_NU } else { $STUB_NU }
  let reported: string = $nu_version | default --empty $version
  let targets: list<string> = $targets | default --empty [(nightly host-target $nu.os-info)]
  let archives: table = $targets | each {|target|
    let base: string = $'nu-($version)-($target)'
    let dir: path = $ctx.code | path join stage $base
    mkdir $dir
    if not $without_nu { stub-nu $ctx ($dir | path join nu) $reported --template $template }
    for plugin in $plugins {
      stub-plugin ($dir | path join $'nu_plugin_($plugin)') (version).version --plugin-version $plugin_version
    }
    'license' | save --force ($dir | path join LICENSE)
    'readme' | save --force ($dir | path join README.txt)
    ^tar -czf ($www | path join $'($base).tar.gz') -C ($dir | path dirname) $base
    {name: $'($base).tar.gz' sha: (open --raw ($www | path join $'($base).tar.gz') | hash sha256)}
  }
  let zeros: string = 1..64 | each { '0' } | str join
  let assets: list = $archives | each {|a|
    let digest: record = match $digest { ok => {digest: $'sha256:($a.sha)'} bad => {digest: $'sha256:($zeros)'} _ => ({}) }
    {name: $a.name browser_download_url: $'($url)/($a.name)'} | merge $digest
  } | append {name: $'nu-($version)-x86_64-pc-windows-msvc.msi' browser_download_url: $'($url)/never.msi'}
  let sums: list = if $sums == none { [] } else {
    if $sums != missing {
      # `unlisted` names another file, so the archive has no line.
      $archives | each {|a| $'(if $sums == ok { $a.sha } else { $zeros })  (if $sums == unlisted { "sbother.tar.gz" } else { $a.name })' }
      | str join "\n" | save --force ($www | path join SHA256SUMS)
    }
    [{name: SHA256SUMS browser_download_url: $'($url)/SHA256SUMS'}]
  }
  let old: string = $'nu-0.0.1-nightly.1-(nightly host-target $nu.os-info).tar.gz'
  [
    {tag_name: '0.0.1-nightly.1+old' published_at: '2026-01-01T00:00:00Z' assets: [{name: $old browser_download_url: $'($url)/($old)'}]}
    {tag_name: $'($version)+fixture' published_at: '2026-11-06T00:00:00Z' assets: ($assets ++ $sums)}
  ] | to json | save --force ($www | path join releases.json)
}

# The `python3` the fixture scripts run on, resolved on the full PATH: the grandchildren run with PATH set to
# `/usr/bin:/bin`, which need not hold one. Skips the test when there is none.
def need-python3 []: nothing -> path {
  which python3 | get $.0?.path? | default { skip 'python3 is not installed' }
}

# Serve `$ctx.code/www` on a localhost port while `action` runs (it receives the base URL). Returns the action's
# value and the requests the server saw, `{path auth}`. Skips without python3.
def with-server [ctx: record action: closure]: nothing -> record {
  let python: path = need-python3
  let www: path = $ctx.code | path join www
  let port: path = $ctx.code | path join port
  let log: path = $ctx.code | path join requests.log
  mkdir $www
  rm --force $port
  let job: int = job spawn { ^$python -I ($FIXTURES | path join pman serve.py) $www $port $log }
  for _ in 1..250 { if ($port | path exists) { break }; sleep 20ms }
  let result: record = try {
    if not ($port | path exists) { error make --unspanned {msg: 'the fixture server did not start'} }
    {value: (do $action $'http://127.0.0.1:(open --raw $port | str trim)')}
  } catch {|e| {error: $e} }
  job kill $job
  if $result has error { $result.error.raw }
  let requests: list = if ($log | path exists) { open --raw $log | lines } else { [] }
  {value: $result.value requests: ($requests | each { split row "\t" | {path: ($in | first) auth: ($in | get 1? | default '')} })}
}

# Run `pman bump-nu <flags>` in a grandchild started from a sandbox copy of `nu`, with HOME/XDG/TMPDIR in the
# sandbox. With `--pty`, the grandchild runs in a pseudo-terminal and the list holds the prompts to answer
# (`expect send` pairs, see the fixture). Returns the command's `{value}` or `{error code help rendered}`, plus
# `output` (stdout and stderr) and `exit_code`.
def run-bump [ctx: record flags: string --vars: record = {} --pty: list<string> --colors]: nothing -> record {
  let exe: path = $ctx.code | path join nubin nu
  if not ($exe | path exists) { mkdir ($exe | path dirname); cp $nu.current-exe $exe }
  let out: path = $ctx.code | path join result.nuon
  rm --force $out
  # `--colors` turns colours on inside the child (it has no terminal, so they are off by default).
  let program: string = ($BUMP | fill-in {'@FLAGS@': $flags '@OUT@': ($out | to nuon)})
    | if $colors { $"$env.config.use_ansi_coloring = true\n($in)" } else { }
  let args: list<string> = [--no-config-file $'--include-path=($ROOT)' --commands $program]
  # Resolved before PATH is narrowed to `/usr/bin:/bin` below, where python3 need not be.
  let python: oneof<path, nothing> = if $pty != null { need-python3 }
  let env_vars: record = {
    HOME: $ctx.home
    XDG_CONFIG_HOME: $ctx.config
    XDG_DATA_HOME: $ctx.data
    XDG_CACHE_HOME: $ctx.cache
    XDG_STATE_HOME: $ctx.state
    TMPDIR: ($ctx.root | path join tmp)
    PATH: ([/usr/bin /bin] | str join (char esep))
  } | merge $vars
  mkdir $env_vars.TMPDIR
  let res: record = with-env $env_vars {
    if $pty == null {
      ^$exe ...$args | complete
    } else {
      ^$python -I ($FIXTURES | path join pman pty.py) 60 ...$pty -- $exe ...$args | complete
    }
  }
  let result: record = if ($out | path exists) { open $out } else { {} }
  $result | merge {output: ($res.stdout + $res.stderr | ansi strip) raw: ($res.stdout + $res.stderr) exit_code: $res.exit_code}
}

# The first argument of every run of the installed stub `nu`.
def nu-runs [ctx: record]: nothing -> list<string> {
  let log: path = $ctx.code | path join nu.log
  if ($log | path exists) { open --raw $log | lines } else { [] }
}

# The request paths, without the leading slash.
def paths []: record -> list<string> { get requests | get path | str replace --regex '^/' '' }

def "test parse assets reads the release naming" []: nothing -> nothing {
  let assets: list = [
    {name: nu-0.116.2-nightly.33-x86_64-unknown-linux-gnu.tar.gz browser_download_url: u1 digest: 'sha256:ab'}
    {name: nu-0.116.2-nightly.33-aarch64-pc-windows-msvc.msi browser_download_url: u2}
    {name: nu-0.116.0-aarch64-apple-darwin.tar.gz browser_download_url: u3}
    {name: SHA256SUMS browser_download_url: u4}
  ]
  let builds: table = $assets | nightly parse-assets
  assert equal ($builds | get name) ($assets | get name | first 3) 'non-builds are dropped'
  assert equal ($builds | get version) [0.116.2-nightly.33 0.116.2-nightly.33 0.116.0] 'nightly and plain versions'
  assert equal ($builds | get target) [x86_64-unknown-linux-gnu aarch64-pc-windows-msvc aarch64-apple-darwin] 'the targets'
  assert equal ($builds | get ext) [tar.gz msi tar.gz] 'the extensions'
  assert equal ($builds | get digest) ['sha256:ab' null null] 'the digest, when listed'
}

def "test host target follows the host" []: nothing -> nothing {
  assert equal (nightly host-target {name: linux arch: x86_64}) x86_64-unknown-linux-gnu 'linux gnu'
  assert equal (nightly host-target {name: linux arch: x86_64} --musl) x86_64-unknown-linux-musl 'linux musl'
  assert equal (nightly host-target {name: linux arch: aarch64} --musl) aarch64-unknown-linux-musl 'musl on any linux arch'
  assert equal (nightly host-target {name: macos arch: aarch64}) aarch64-apple-darwin 'macos'
  assert equal (nightly host-target {name: windows arch: x86_64}) x86_64-pc-windows-msvc 'windows'
}

def "test musl needs linux" []: nothing -> nothing {
  for os in [macos windows] {
    let e = try { nightly host-target {name: $os arch: x86_64} --musl; null } catch {|e| $e }
    assert equal ($e.details?.code?) pman::nightly::host-target::unsupported $'--musl on ($os)'
  }
}

def "test is under compares path components" []: nothing -> nothing {
  assert ('/home/u/bin' | nightly is-under /home/u) 'a subdirectory'
  assert ('/home/u' | nightly is-under /home/u) 'the directory itself'
  assert not ('/home/u2/bin' | nightly is-under /home/u) 'a sibling sharing the prefix'
  assert not ('/opt/home/u/bin' | nightly is-under /home/u) 'a path that merely contains it'
  assert not ('/home/u/../v' | nightly is-under /home/u) 'after expansion'
}

def "test the github token goes to the github api only" []: nothing -> nothing {
  with-env {GITHUB_TOKEN: sbtoken} {
    assert equal (nightly api-headers $nightly.SOURCE) {Authorization: 'Bearer sbtoken'} 'the GitHub API'
    assert equal (nightly api-headers 'http://127.0.0.1:8000/releases.json') {} 'any other host'
  }
  hide-env --ignore-errors GITHUB_TOKEN
  assert equal (nightly api-headers $nightly.SOURCE) {} 'no token, no header'
}

def "test bump nu without a terminal fails fast" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx (flags $ctx $url)
    }
    assert equal $r.value.code pman::nightly::bump-nu::unsupported $'the error: ($r.value.output)'
    assert ($r.value.help =~ '--yes') $'it points at --yes: ($r.value.help)'
    assert equal $r.requests [] 'before fetching anything'
  }
}

def "test bump nu interactive without a terminal fails fast" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes --interactive'
    }
    assert equal $r.value.code pman::nightly::bump-nu::unsupported $'the error: ($r.value.output)'
    assert equal $r.requests [] 'before fetching anything'
  }
}

def "test bump nu outside the home directory needs elevation" []: nothing -> nothing {
  if (is-admin) { skip 'running as an administrator' }
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'--yes --source ($url)/releases.json --install-dir /usr/local/sbpman-nope'
    }
    assert equal $r.value.code pman::nightly::install-dir::unsupported $'the error: ($r.value.output)'
    assert equal $r.requests [] 'before fetching anything'
  }
}

def "test bump nu colours its log lines only when colours are on" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      {off: (run-bump $ctx $'(flags $ctx $url) --check') on: (run-bump $ctx $'(flags $ctx $url) --check' --colors)}
    }
    assert str contains $r.value.off.raw 'fetching the latest release' 'the log line is written either way'
    assert ($r.value.off.raw !~ '\e\[') 'no escape sequences off a terminal'
    assert ($r.value.on.raw =~ '\e\[') 'escape sequences when use_ansi_coloring is true'
  }
}

def "test bump nu check reports without downloading" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --check'
    }
    let asset: string = $'nu-($NEWER)-(nightly host-target $nu.os-info).tar.gz'
    assert equal $r.value.value {current: null latest: $NEWER up_to_date: false asset: $asset previous: null} 'the report: no nu is installed there yet'
    assert equal ($r | paths) [releases.json] 'only the release metadata is fetched'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
  }
}

def "test bump nu stops when the installed nu is the latest nightly" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url (version).version
      # The default install directory holds the running copy of `nu`.
      run-bump $ctx $'--yes --source ($url)/releases.json --plugin-config ($ctx | registry | to nuon)'
    }
    assert equal [$r.value.value.current $r.value.value.up_to_date] [(version).version true] $'up to date: ($r.value.output)'
    assert equal [$r.value.value.installed $r.value.value.plugins] [[] []] 'nothing installed'
    assert ($r.value.output =~ 'already the latest nightly') 'it says so'
    assert equal ($r | paths) [releases.json] 'before downloading'
  }
}

def "test bump nu compares the installed nu not the running one" []: nothing -> nothing {
  with-sandbox {|ctx|
    stub-nu $ctx ($ctx | bin-dir | path join nu) '0.100.0'
    let r: record = with-server $ctx {|url|
      release $ctx $url (version).version
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal [$r.value.value.current $r.value.value.up_to_date] ['0.100.0' false] $'a stable nu on disk is not up to date: ($r.value.output)'
    assert equal ($r.value.value.installed | length) 1 'it is replaced, although the running nu is the latest'
    assert equal (^($ctx | bin-dir | path join nu) --version | str trim) (version).version 'by the nightly'
  }
}

def "test bump nu installs the newest release" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --plugins [sbextra]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    let asset: string = $'nu-($NEWER)-(nightly host-target $nu.os-info).tar.gz'
    let bin: path = $ctx | bin-dir
    assert equal ($r.value.value | reject installed plugins) {current: null latest: $NEWER up_to_date: false asset: $asset} $'the newest release, listed last: ($r.value.output)'
    assert equal $r.value.value.installed [($bin | path join nu) ($bin | path join nu_plugin_sbextra)] 'nu first, then the plugins'
    assert equal (open --raw ($bin | path join nu) | lines | first) '#!/bin/sh' "the archive's nu"
    assert equal (ls --all $bin | get name | path basename | sort) [nu nu_plugin_sbextra] 'no LICENSE, README or staging files'
    assert equal ($r | paths) [releases.json $asset] 'the metadata, then the archive'
    assert equal (ls --all ($ctx.root | path join tmp)) [] 'the download is cleaned up'
  }
}

def "test bump nu installs the musl build" []: nothing -> nothing {
  if $nu.os-info.name != linux { skip 'musl builds are Linux only' }
  with-sandbox {|ctx|
    let gnu: string = nightly host-target $nu.os-info
    let musl: string = nightly host-target $nu.os-info --musl
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --targets [$gnu $musl]
      run-bump $ctx $'(flags $ctx $url) --yes --musl'
    }
    assert equal $r.value.value.asset $'nu-($NEWER)-($musl).tar.gz' $'the musl archive: ($r.value.output)'
  }
}

def "test bump nu without a build for the host fails" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --targets [sbarch-unknown-sbos]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::pick-build::not_found $'the error: ($r.value.output)'
    assert ($r.value.help =~ 'sbarch-unknown-sbos') $'the available builds are listed: ($r.value.help)'
  }
}

def "test bump nu rejects an archive without nu" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --without-nu --plugins [sbextra]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::extract::not_found $'the error: ($r.value.output)'
    assert not ($ctx | bin-dir | path exists) 'not even the plugins are installed'
  }
}

def "test bump nu rejects an archive that does not match its digest" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest bad
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::download::io $'the error: ($r.value.output)'
    assert ($r.value.help =~ 'expected 0+, got [0-9a-f]+') $'the digests are the advice: ($r.value.help)'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
    assert equal (ls --all ($ctx.root | path join tmp)) [] 'the download is cleaned up'
  }
}

def "test bump nu checks SHA256SUMS when there is no digest" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest none --sums bad
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::download::io $'the error: ($r.value.output)'
    assert ('SHA256SUMS' in ($r | paths)) 'the checksums are fetched'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
  }
}

def "test bump nu reports a SHA256SUMS that cannot be fetched" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest none --sums missing
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::published-sha256::io $'the error: ($r.value.output)'
    assert ($r.value.error =~ "'SHA256SUMS'") $'it names the asset: ($r.value.error)'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
    assert equal (ls --all ($ctx.root | path join tmp)) [] 'the download is cleaned up'
  }
}

def "test bump nu installs after a matching SHA256SUMS" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest none --sums ok
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert ($r.value.output =~ 'verified the sha256') $'verified: ($r.value.output)'
    assert ($ctx | bin-dir | path join nu | path exists) 'installed'
  }
}

def "test bump nu refuses an archive that SHA256SUMS does not list" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest none --sums unlisted
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code? pman::nightly::download::io $'the error: ($r.value.output)'
    assert ($r.value.error =~ "^SHA256SUMS does not list 'nu-") $'it names the checksum file and the archive: ($r.value.error)'
    assert ($r.value.help =~ 'incomplete') $'the advice says why: ($r.value.help)'
    assert ('SHA256SUMS' in ($r | paths)) 'the checksums are fetched'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
    assert equal (ls --all ($ctx.root | path join tmp)) [] 'the download is cleaned up'
  }
}

def "test bump nu skips verification when no checksum is published" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest none
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert ($ctx | bin-dir | path join nu | path exists) $'installed: ($r.value.output)'
    assert not ($r.value.output =~ 'verified') 'silently unverified'
  }
}

def "test bump nu never sends the github token elsewhere" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes' --vars {GITHUB_TOKEN: sbtoken}
    }
    assert ($r.requests | is-not-empty) $'requests were made: ($r.value.output)'
    assert equal ($r.requests | get auth | uniq) [''] 'no Authorization header'
  }
}

def "test bump nu replaces the running binary atomically" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'--yes --source ($url)/releases.json --plugin-config ($ctx | registry | to nuon)'
    }
    let nubin: path = $ctx.code | path join nubin
    assert equal $r.value.value.installed [($nubin | path join nu)] $'the running nu is the default target: ($r.value.output)'
    assert equal (open --raw ($nubin | path join nu) | lines | first) '#!/bin/sh' 'it is replaced'
    assert equal (ls --all $nubin | get name | path basename | sort) [nu nu.previous] 'by a rename, keeping the replaced nu: no staging file is left'
    assert ($r.value.output =~ 'replaced the running nu') 'and says how to pick it up'
  }
}

def "test bump nu reload execs the installed nu" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes --reload'
    }
    assert equal $r.value.exit_code 0 $'the exec succeeds: ($r.value.output)'
    assert equal ($r.value | columns) [output raw exit_code] 'the process was replaced before it could save a result'
    assert equal (nu-runs $ctx | last) 'run:' 'the installed nu ran, without arguments'
  }
}

# ——— bump-nu: smoke test, previous build, rollback ————————————————————————————

def "test bump nu smoke tests the new nu before installing" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal (nu-runs $ctx | first 2) ['run:--no-config-file --commands' 'run:--no-config-file --login'] $'the version, then the library load as a login shell: ($r.value.output)'
    let out: string = $r.value.output
    assert (($out | str index-of 'smoke-testing') < ($out | str index-of 'installed ')) 'before anything is installed'
  }
}

def "test the smoke test imports the barrel and every module directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes'
    } | ignore
    let program: string = open --raw ($ctx.code | path join nu.log.login)
    let imported: list<string> = $program | split row '; ' | where $it starts-with 'use '
      | each { str replace --regex '^use (.+?)( \*)?$' '$1' | from nuon | path basename }
    let expected: list<string> = glob ($ROOT | path join '*' mod.nu) | path dirname | path basename
    assert equal ($imported | first) ($ROOT | path basename) $'the barrel first: ($program)'
    # `drop nth 0`, not `skip 1`: `skip` is the runner's command in a suite.
    assert equal ($imported | drop nth 0 | sort) ($expected | sort) 'then every module directory under the root'
    assert ([util var mount _tests] | all $it in $expected) 'those the barrel does not expose included'
  }
}

def "test bump nu refuses a nu that does not run" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --broken-nu
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::smoke-test::external_failure $'the error: ($r.value.output)'
    assert ($r.value.error =~ '^the new nu does not run') $'the message: ($r.value.error)'
    assert equal $r.value.help 'sbstub: broken' 'its stderr is the advice'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
    let archive: path = $r.value.error | parse --regex "kept at '(?<archive>[^']+)'" | get 0.archive
    assert equal ($archive | path basename) $'nu-($NEWER)-(nightly host-target $nu.os-info).tar.gz' $'the message names the archive: ($r.value.error)'
    assert ($archive | path exists) 'which is kept'
    assert equal ($archive | path dirname | path dirname) ($ctx.root | path join tmp) 'in the temp dir'
  }
}

def "test no smoke installs a nu that does not run" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --broken-nu
      run-bump $ctx $'(flags $ctx $url) --yes --no-smoke'
    }
    assert equal ($r.value.value.installed | length) 1 $'installed: ($r.value.output)'
    assert not ($r.value.output =~ 'smoke-testing') 'without a smoke test'
    assert equal (ls --all ($ctx.root | path join tmp)) [] 'the download is cleaned up'
  }
}

def "test bump nu refuses a nu that cannot load the library" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --version-only-nu
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::smoke-test::external_failure $'the error: ($r.value.output)'
    assert ($r.value.error =~ $'^nu ($NEWER) cannot load this library') $'the message: ($r.value.error)'
    assert ($r.value.help =~ 'sbstub: cannot load') $'its stderr is the advice: ($r.value.help)'
    assert ($r.value.help =~ '--no-smoke') 'which names the way around'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
  }
}

def "test bump nu refuses a nu whose login shell fails" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      # Loads the library in a plain `--commands` run; only the login shell, where `conf`'s loader runs, fails.
      release $ctx $url $NEWER --login-failing-nu
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::smoke-test::external_failure $'the error: ($r.value.output)'
    assert ($r.value.error =~ $'^nu ($NEWER) cannot load this library') $'the message: ($r.value.error)'
    assert ($r.value.help =~ 'sbstub: the conf loader fails') $'its stderr is the advice: ($r.value.help)'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
  }
}

def "test bump nu refuses a nu of another version" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      # The archive is named after `NEWER`, its `nu` reports `OLDER`.
      release $ctx $url $NEWER --nu-version $OLDER
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::nightly::smoke-test::external_failure $'the error: ($r.value.output)'
    assert ($r.value.error =~ $"reports version '($OLDER)', not '($NEWER)'") $'the message: ($r.value.error)'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
  }
}

# Install `OLDER` as the sandbox's `nu`, with a registered `sbship` plugin 0.1.0 next to it, then bump to `NEWER`,
# whose archive ships `sbship` 0.2.0. Returns the bump's result.
def bump-over-older [ctx: record url: string]: nothing -> record {
  let bin: path = $ctx | bin-dir
  stub-nu $ctx ($bin | path join nu) $OLDER
  register $ctx {sbship: $bin}
  release $ctx $url $NEWER --plugins [sbship] --plugin-version '0.2.0'
  run-bump $ctx $'(flags $ctx $url) --yes'
}

def "test bump nu keeps the previous nu and plugins" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      let bump: record = bump-over-older $ctx $url
      {bump: $bump check: (run-bump $ctx $'(flags $ctx $url) --check')}
    }
    let bin: path = $ctx | bin-dir
    assert equal ($r.value.bump.value.installed | path basename) [nu nu_plugin_sbship] $'installed: ($r.value.bump.output)'
    assert equal (ls --all $bin | get name | path basename | sort) [nu nu.previous nu_plugin_sbship nu_plugin_sbship.previous] 'each replaced file is kept'
    assert equal (^($bin | path join nu.previous) --version | str trim) $OLDER 'the previous nu'
    assert equal (^($bin | path join nu) --version | str trim) $NEWER 'next to the new one'
    assert ((open --raw ($bin | path join nu_plugin_sbship.previous)) =~ '"0.1.0"') 'the previous plugin'
    assert equal (plugin-versions $ctx) {sbship: '0.2.0'} 'the registry holds the shipped plugin'
    let asset: string = $'nu-($NEWER)-(nightly host-target $nu.os-info).tar.gz'
    assert equal $r.value.check.value {current: $NEWER latest: $NEWER up_to_date: true asset: $asset previous: $OLDER} '--check reports the previous version'
  }
}

def "test rollback restores the previous build and its plugins" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      bump-over-older $ctx $url | ignore
      run-bump $ctx $'(flags $ctx $url) --rollback'
    }
    let bin: path = $ctx | bin-dir
    let shipped: path = $bin | path join nu_plugin_sbship
    assert equal ($r.value.value | reject plugins) {current: $OLDER previous: $NEWER installed: [($bin | path join nu) $shipped]} $'the report: ($r.value.output)'
    assert equal $r.value.value.plugins [{name: sbship filename: $shipped action: updated message: null}] 'the plugin is re-registered from the restored copy'
    assert equal (^($bin | path join nu) --version | str trim) $OLDER 'the previous nu is back'
    assert equal (^($bin | path join nu.previous) --version | str trim) $NEWER 'the builds swap'
    assert equal (plugin-versions $ctx) {sbship: '0.1.0'} 'the registry holds the restored plugin'
    assert equal (ls --all $bin | get name | path basename | sort) [nu nu.previous nu_plugin_sbship nu_plugin_sbship.previous] 'no staging files'
    assert equal ($r | paths) [releases.json $'nu-($NEWER)-(nightly host-target $nu.os-info).tar.gz'] 'the rollback fetches nothing'
    assert not ($r.value.output =~ 'replaced the running nu') 'the running nu was not the target'
  }
}

def "test rollback without a previous build errors" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = run-bump $ctx $'--rollback --install-dir ($ctx | bin-dir | to nuon) --plugin-config ($ctx | registry | to nuon)'
    assert equal $r.code pman::nightly::rollback::not_found $'the error: ($r.output)'
    assert ($r.help =~ 'nu.previous') $'the advice says what it needs: ($r.help)'
  }
}

def "test rollback cannot be combined with check" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = run-bump $ctx $'--rollback --check --install-dir ($ctx | bin-dir | to nuon)'
    assert equal $r.code pman::nightly::bump-nu::invalid_argument $'the error: ($r.output)'
  }
}

# ——— upgrade: the auto-bump ———————————————————————————————————————————————————
#
# `stubbed-upgrade --clobber-nu` makes the `cargo` stub leave a stable `nu` where the sandbox copy was; the bump
# that `upgrade` then runs reads the release `release` wrote through the `http get` shadow (no server, no network).

def "test upgrade reinstalls the nightly when cargo leaves a stable nu" []: nothing -> nothing {
  with-sandbox {|ctx|
    release $ctx 'http://sbfixture' $NEWER
    let r: record = stubbed-upgrade $ctx 'pman upgrade' --clobber-nu
    let nubin: path = $ctx.code | path join nubin
    assert equal ($r.value | columns) ($REGISTRY_BINS ++ [nu]) $'the bump is one more entry: ($r.stderr)'
    assert equal $r.value.nu [{output: $'installed nu ($NEWER) over nu 0.100.0' success: true}] 'its outcome'
    assert equal (^($nubin | path join nu) --version | str trim) $NEWER 'the smoke-tested nightly replaced the stable build'
    assert equal (^($nubin | path join nu.previous) --version | str trim) '0.100.0' 'which is kept'
    assert ($r.stderr =~ 'smoke-testing') 'through the smoke test'
  }
}

def "test upgrade reports a bump that refused the build" []: nothing -> nothing {
  with-sandbox {|ctx|
    release $ctx 'http://sbfixture' $NEWER --broken-nu
    let r: record = stubbed-upgrade $ctx 'pman upgrade' --clobber-nu
    let nubin: path = $ctx.code | path join nubin
    let row: record = $r.value.nu | first
    assert equal $row.success false $'the bump failed: ($r.stderr)'
    assert ($row.output =~ '^nu 0.100.0 stays: the new nu does not run') $'the error, naming what stays: ($row.output)'
    assert ($row.output =~ 'sbstub: broken') 'with its advice'
    assert equal (^($nubin | path join nu) --version | str trim) '0.100.0' 'the stable build stays'
    assert not ($nubin | path join nu.previous | path exists) 'nothing was replaced'
    assert equal ($r.value.bun | get success) [true true] 'the other upgrades still ran'
  }
}

def "test bump nu updates and checks the registered plugins" []: nothing -> nothing {
  with-sandbox {|ctx|
    register $ctx {sbship: ($ctx.home | path join old) sbkeep: ($ctx.home | path join plugins)}
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --plugins [sbship]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    let shipped: path = $ctx | bin-dir | path join nu_plugin_sbship
    let kept: path = $ctx.home | path join plugins nu_plugin_sbkeep
    assert equal ($r.value.value.plugins | sort-by name) [
      {name: sbkeep filename: $kept action: kept message: null}
      {name: sbship filename: $shipped action: updated message: null}
    ] $'the outcomes: ($r.value.output)'
    assert equal (registered $ctx) {sbkeep: $kept sbship: $shipped} 'a shipped plugin is registered from its installed copy'
    assert ($ctx.home | path join old nu_plugin_sbship | path exists) 'its old binary is kept'
    assert equal (nu-runs $ctx | last) 'run:--no-config-file --stdin' 'the new nu checked the registry'
  }
}

def "test bump nu unregisters plugins that fail to load" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.home | path join plugins
    register $ctx {sbold: $dir sbkeep: $dir}
    stub-plugin ($dir | path join nu_plugin_sbold) 0.90.0
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    let old: record = $r.value.value.plugins | where name == sbold | first
    assert equal $old.action removed $'unregistered: ($r.value.output)'
    assert ($old.message =~ 'compiled for nushell version 0.90.0') $'the reason: ($old.message)'
    assert equal (registered $ctx | columns) [sbkeep] 'only the loading plugin stays registered'
    assert ($dir | path join nu_plugin_sbold | path exists) 'its binary is kept'
    assert ($r.value.output =~ 'unregistered') 'reported as a warning'
  }
}

def "test bump nu warns about plugins before installing" []: nothing -> nothing {
  with-sandbox {|ctx|
    register $ctx {sbship: ($ctx.home | path join old) sbkeep: ($ctx.home | path join plugins)}
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --plugins [sbship]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    let out: string = $r.value.output
    let warned: int = $out | str index-of 'are updated from the archive: sbship'
    assert ($warned >= 0) $'shipped plugins: ($out)'
    assert ($out =~ 'may fail to load on 0.999.0-nightly.1.*sbkeep 0.1.0') 'separately built plugins'
    assert ($warned < ($out | str index-of 'installed ')) 'before installing'
  }
}

def "test bump nu leaves unregistered archive plugins unregistered" []: nothing -> nothing {
  with-sandbox {|ctx|
    register $ctx {sbkeep: ($ctx.home | path join plugins)}
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --plugins [sbextra]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert ($ctx | bin-dir | path join nu_plugin_sbextra | path exists) $'installed: ($r.value.output)'
    assert equal (registered $ctx | columns) [sbkeep] 'but not registered'
  }
}

def "test a new nu that cannot check plugins does not abort the bump" []: nothing -> nothing {
  with-sandbox {|ctx|
    register $ctx {sbkeep: ($ctx.home | path join plugins)}
    let before: record = registered $ctx
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --broken-nu
      run-bump $ctx $'(flags $ctx $url) --yes --no-smoke'
    }
    assert equal ($r.value.value.installed | length) 1 $'installed: ($r.value.output)'
    assert equal ($r.value.value.plugins | get action) [failed] 'the plugin is reported'
    assert equal (registered $ctx) $before 'and left registered'
  }
}

def "test an unreadable plugin registry does not abort the bump" []: nothing -> nothing {
  with-sandbox {|ctx|
    'not a registry' | save ($ctx | registry)
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal ($r.value.value.installed | length) 1 $'installed: ($r.value.output)'
    assert ($r.value.output =~ 'could not read the plugin registry') 'a warning'
  }
}

def "test bump nu installs after confirmation" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx (flags $ctx $url) --pty ['\[y/N\]' 'y\r']
    }
    assert ($r.value.output =~ 'install nu-.* \(1 binaries\) into') $'the prompt: ($r.value.output)'
    assert ($ctx | bin-dir | path join nu | path exists) $'installed: ($r.value | reject output)'
  }
}

def "test bump nu installs nothing when declined" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx (flags $ctx $url) --pty ['\[y/N\]' 'n\r']
    }
    assert equal $r.value.code pman::nightly::confirm::invalid_argument $'aborted: ($r.value.output)'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
    assert equal (ls --all ($ctx.root | path join tmp)) [] 'the download is cleaned up'
  }
}

def "test bump nu interactive without a choice aborts" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --interactive' --pty ['Choose a build' '\x1b']
    }
    assert equal $r.value.code pman::nightly::pick-build::invalid_argument $'aborted: ($r.value.output)'
    assert equal ($r | paths) [releases.json] 'nothing is downloaded'
  }
}

