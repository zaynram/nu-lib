# `pman`: `test _tests/suites/pman.nu`.
#
# pman runs package managers, `sudo` and plugin commands. Nothing real is ever run here:
# - `install`/`remove`/`clean`/`apt` run in sandboxed children with stub `sudo`/`apt-get` first on PATH.
# - `upgrade` first puts `machine-config user`'s binary directories on PATH, and the first one is the directory of
#   the running `nu` (which, on the owner's machine, also holds the real `rustup`/`cargo`). It therefore runs in a
#   grandchild started from a *copy* of the `nu` binary inside the sandbox, with stubs for every registry binary
#   in the sandbox `~/.local/bin`; the grandchild refuses to run if any binary directory is outside the sandbox.
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

# Write an executable stub that appends `<name> <args>` to `log` and echoes it (or fails, with `--fail`).
def stub [dir: path name: path log: path --fail]: nothing -> nothing {
  mkdir $dir
  let body: string = if $fail {
    $'echo "($name) failed: $*" >&2(char newline)exit 3'
  } else {
    $'echo "($name) $*" >> "($log)"(char newline)echo "($name) $*"'
  }
  $"#!/bin/sh\n($body)\n" | save --force ($dir | path join $name)
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

# Run `code` with `pman` in a grandchild started from a copy of `nu` in the sandbox, with stubs for every
# registry binary (and `sudo`/`apt-get`) in the sandbox `~/.local/bin`. `failing` stubs exit non-zero.
def stubbed-upgrade [ctx: record code: string --failing: list<string> = []]: nothing -> record {
  let nubin: path = $ctx.code | path join nubin
  mkdir $nubin
  cp $nu.current-exe ($nubin | path join nu)
  let local: path = $ctx.home | path join .local bin
  let log: path = $ctx.code | path join calls.log
  for name in ($REGISTRY_BINS ++ [sudo apt-get]) { stub $local $name $log --fail=($name in $failing) }
  let guard: string = '
    use conf/machine.nu [ machine-config ]
    let outside = (machine-config user).binaries | where {|d| not ($d starts-with $env.HOME) and not ($d starts-with $env.SBPMAN_NUBIN) }
    if $outside != [] { error make --unspanned {msg: $"refusing to run: binaries outside the sandbox: ($outside)"} }
    use pman
  '
  let vars: record = {
    HOME: $ctx.home
    XDG_CONFIG_HOME: $ctx.config
    XDG_DATA_HOME: $ctx.data
    XDG_CACHE_HOME: $ctx.cache
    XDG_STATE_HOME: $ctx.state
    PATH: ([/usr/bin /bin] | str join (char esep))
    SBPMAN_NUBIN: $nubin
  }
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
  assert ($pman.REGISTRY | values | all {|v| ($v | describe) =~ '^list<list' }) 'each entry is a list of argument sets'
}

def "test log lives in the cache dir" []: nothing -> nothing {
  assert equal $pman.LOG.upgrade ($nu.cache-dir | path join update_results.nuon) 'the upgrade log path'
}

def "test bump nu is exported" []: nothing -> nothing {
  let names: list<string> = scope commands | get name | where $it starts-with 'pman '
  assert ('pman bump-nu' in $names) 'the nightly installer'
  assert not ($names | any { $in =~ 'nightly' }) "the submodule's helpers stay private"
}

# ——— history ——————————————————————————————————————————————————————————————————

def "test history rejects an unknown target" []: nothing -> nothing {
  assert error {|| pman history nope } 'only LOG targets'
}

def "test history of a missing log" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = sandboxed $ctx '{log: (pman history upgrade) age: (pman history upgrade --age)} | to nuon' --prelude 'use pman' --pipe
    assert equal $r {log: null age: null} 'a missing log is null'
    let res: record = sandboxed $ctx 'pman history upgrade --throw' --prelude 'use pman'
    assert ($res.exit_code != 0 and $res.stderr =~ 'no cached results found') '--throw raises'
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
  assert error {|| pman install } 'no packages is an error'
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
  assert error {|| pman upgrade --async --system } 'sudo needs a prompt'
}

def "test upgrade runs every registry entry" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = stubbed-upgrade $ctx 'pman upgrade'
    assert equal ($r.value | columns) $REGISTRY_BINS 'one result per binary'
    assert equal $r.value.rustup [{output: "rustup upgrade\n" success: true}] 'stdout of a successful call'
    assert equal ($r.value.pixi | get output) ["pixi self-update\n" "pixi global update\n"] 'argument sets run in order'
    assert equal ($r.calls | where $it starts-with bun) ['bun upgrade --canary' 'bun --global update'] 'every set runs, one after another, in order'
    assert not ($r.calls | any { $in starts-with 'sudo' }) 'no system packages without --system'
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
    assert not ($r.calls | any { $in starts-with 'dprint' }) 'the overridden entry does not run'
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
# stub `nu` (it logs its first argument, hands `--commands` runs to the real `nu`, and otherwise exits) and stub
# plugins that speak just enough of the plugin protocol for `plugin add`. Prompts are answered through a
# pseudo-terminal (`run-bump --pty`).

const NEWER: string = '0.999.0-nightly.1'

# The `nu` of the fixture archives (see the section comment); @LOG@ and @NU@ are filled in by `release`.
const STUB_NU: string = r##'#!/bin/sh
printf 'run:%s\n' "$1" >> '@LOG@'
case " $* " in *" --commands "*) exec '@NU@' "$@" ;; esac
exit 0
'##

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

# Write an executable stub plugin built for nushell `version` (see the fixture).
def stub-plugin [file: path version: string]: nothing -> nothing {
  mkdir ($file | path dirname)
  open --raw ($FIXTURES | path join pman nu_plugin_stub.sh) | str replace --all '@VERSION@' $version | save --force $file
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

# Write a release fixture into `$ctx.code/www`: `releases.json` lists an older release first, then the release of
# `version` with one `.tar.gz` per target (a stub `nu`, the stub `plugins`, LICENSE and README.txt) and an `.msi`.
# `--digest`/`--sums` (`ok`, `bad`, `none`) set the archives' `digest` and a `SHA256SUMS` asset.
def release [
  ctx: record
  url: string
  version: string
  --targets: list<string> = []
  --plugins: list<string> = []
  --digest: string = ok
  --sums: string = none
  --broken-nu # The archives' `nu` fails every run
  --without-nu # The archives hold no `nu`
]: nothing -> nothing {
  let www: path = $ctx.code | path join www
  mkdir $www
  let stub: string = if $broken_nu { "#!/bin/sh\nexit 1\n" } else {
    $STUB_NU | str replace '@LOG@' ($ctx.code | path join nu.log) | str replace '@NU@' $nu.current-exe
  }
  let targets: list<string> = $targets | default --empty [(nightly host-target $nu.os-info)]
  let archives: table = $targets | each {|target|
    let base: string = $'nu-($version)-($target)'
    let dir: path = $ctx.code | path join stage $base
    mkdir $dir
    if not $without_nu {
      $stub | save --force ($dir | path join nu)
      ^chmod +x ($dir | path join nu)
    }
    for plugin in $plugins { stub-plugin ($dir | path join $'nu_plugin_($plugin)') (version).version }
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
    $archives | each {|a| $'(if $sums == ok { $a.sha } else { $zeros })  ($a.name)' } | str join "\n" | save --force ($www | path join SHA256SUMS)
    [{name: SHA256SUMS browser_download_url: $'($url)/SHA256SUMS'}]
  }
  let old: string = $'nu-0.0.1-nightly.1-(nightly host-target $nu.os-info).tar.gz'
  [
    {tag_name: '0.0.1-nightly.1+old' published_at: '2026-01-01T00:00:00Z' assets: [{name: $old browser_download_url: $'($url)/($old)'}]}
    {tag_name: $'($version)+fixture' published_at: '2026-11-06T00:00:00Z' assets: ($assets ++ $sums)}
  ] | to json | save --force ($www | path join releases.json)
}

# Serve `$ctx.code/www` on a localhost port while `action` runs (it receives the base URL). Returns the action's
# value and the requests the server saw, `{path auth}`. Skips without python3.
def with-server [ctx: record action: closure]: nothing -> record {
  if (which python3 | is-empty) { skip 'python3 is not installed' }
  let www: path = $ctx.code | path join www
  let port: path = $ctx.code | path join port
  let log: path = $ctx.code | path join requests.log
  mkdir $www
  rm --force $port
  let job: int = job spawn { ^python3 -I ($FIXTURES | path join pman serve.py) $www $port $log }
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
def run-bump [ctx: record flags: string --vars: record = {} --pty: list<string>]: nothing -> record {
  let exe: path = $ctx.code | path join nubin nu
  if not ($exe | path exists) { mkdir ($exe | path dirname); cp $nu.current-exe $exe }
  let out: path = $ctx.code | path join result.nuon
  rm --force $out
  let program: string = $BUMP | str replace '@FLAGS@' $flags | str replace '@OUT@' ($out | to nuon)
  let args: list<string> = [--no-config-file $'--include-path=($ROOT)' --commands $program]
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
      ^python3 -I ($FIXTURES | path join pman pty.py) 60 ...$pty -- $exe ...$args | complete
    }
  }
  let result: record = if ($out | path exists) { open $out } else { {} }
  $result | merge {output: ($res.stdout + $res.stderr | ansi strip) exit_code: $res.exit_code}
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
    assert equal ($e.details?.code?) pman::bump-nu::invalid_option $'--musl on ($os)'
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
    assert equal $r.value.code pman::bump-nu::no_terminal $'the error: ($r.value.output)'
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
    assert equal $r.value.code pman::bump-nu::no_terminal $'the error: ($r.value.output)'
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
    assert equal $r.value.code pman::bump-nu::elevation $'the error: ($r.value.output)'
    assert equal $r.requests [] 'before fetching anything'
  }
}

def "test bump nu check reports without downloading" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER
      run-bump $ctx $'(flags $ctx $url) --check'
    }
    let asset: string = $'nu-($NEWER)-(nightly host-target $nu.os-info).tar.gz'
    assert equal $r.value.value {current: (version).version latest: $NEWER up_to_date: false asset: $asset} 'the report'
    assert equal ($r | paths) [releases.json] 'only the release metadata is fetched'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
  }
}

def "test bump nu stops when the latest nightly is running" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url (version).version
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.value.up_to_date true $'up to date: ($r.value.output)'
    assert equal [$r.value.value.installed $r.value.value.plugins] [[] []] 'nothing installed'
    assert ($r.value.output =~ 'already the latest nightly') 'it says so'
    assert equal ($r | paths) [releases.json] 'before downloading'
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
    assert equal ($r.value.value | reject installed plugins) {current: (version).version latest: $NEWER up_to_date: false asset: $asset} $'the newest release, listed last: ($r.value.output)'
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
    assert equal $r.value.code pman::bump-nu::no_build $'the error: ($r.value.output)'
    assert ($r.value.help =~ 'sbarch-unknown-sbos') $'the available builds are listed: ($r.value.help)'
  }
}

def "test bump nu rejects an archive without nu" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --without-nu --plugins [sbextra]
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::bump-nu::missing_binary $'the error: ($r.value.output)'
    assert not ($ctx | bin-dir | path exists) 'not even the plugins are installed'
  }
}

def "test bump nu rejects an archive that does not match its digest" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = with-server $ctx {|url|
      release $ctx $url $NEWER --digest bad
      run-bump $ctx $'(flags $ctx $url) --yes'
    }
    assert equal $r.value.code pman::bump-nu::checksum $'the error: ($r.value.output)'
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
    assert equal $r.value.code pman::bump-nu::checksum $'the error: ($r.value.output)'
    assert ('SHA256SUMS' in ($r | paths)) 'the checksums are fetched'
    assert not ($ctx | bin-dir | path exists) 'nothing is installed'
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
    assert equal (ls --all $nubin | get name | path basename) [nu] 'by a rename: no staging file is left'
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
    assert equal ($r.value | columns) [output exit_code] 'the process was replaced before it could save a result'
    assert equal (nu-runs $ctx) ['run:'] 'the installed nu ran, without arguments'
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
    assert equal (nu-runs $ctx) ['run:--no-config-file'] 'the new nu checked the registry'
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
      run-bump $ctx $'(flags $ctx $url) --yes'
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
    assert equal $r.value.code pman::bump-nu::aborted $'aborted: ($r.value.output)'
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
    assert equal $r.value.code pman::bump-nu::aborted $'aborted: ($r.value.output)'
    assert equal ($r | paths) [releases.json] 'nothing is downloaded'
  }
}

