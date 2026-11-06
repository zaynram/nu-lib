# `pman`: `test _tests/suites/pman.nu`.
#
# pman runs package managers, `sudo` and plugin commands. Nothing real is ever run here:
# - `install`/`remove`/`clean`/`apt` run in sandboxed children with stub `sudo`/`apt-get` first on PATH.
# - `upgrade` first puts `machine-config user`'s binary directories on PATH, and the first one is the directory of
#   the running `nu` (which, on the owner's machine, also holds the real `rustup`/`cargo`). It therefore runs in a
#   grandchild started from a *copy* of the `nu` binary inside the sandbox, with stubs for every registry binary
#   in the sandbox `~/.local/bin`; the grandchild refuses to run if any binary directory is outside the sandbox.
# - `reload-plugins` runs with the `plugin` commands and `cargo` shadowed by definitions made before `use pman`.
# nu-lint-ignore-file: missing_output_type
# (helpers return whatever the child produced)
use pman
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

def "test the nightly installer is re-exported" []: nothing -> nothing {
  assert ('pman get-latest-nightly-build' in (scope aliases | get name)) 'from the vendored nightly-toolkit'
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
    assert equal ($r.calls | where $it starts-with bun | sort) ['bun --global update' 'bun upgrade --canary'] 'every set runs'
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

# Shadow the plugin commands (definitions made before `use pman` are seen by it) and `cargo`.
const PLUGIN_STUBS: string = '
def "plugin list" [] { [[name filename version]; [sbbroken /x/nu_plugin_sbbroken 0.1] [sbgood /x/nu_plugin_sbgood 0.2]] }
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
