# The root barrel (`mod.nu` at the library root): `test _tests/suites/barrel.nu`.
#
# Loading the barrel flattens many names and runs environment set-up, so every case loads it in a fresh child:
# `sandboxed` for plain (non-login, non-interactive) children, and a sandboxed `nu --login --interactive`
# child for the guarded loaders. The barrel needs nothing outside the repository.
# nu-lint-ignore-file: missing_output_type
# (helpers return whatever the child produced)
use ../mod.nu *

const USE_BARREL: string = $'use ($ROOT) *'

# Run `code` (serialized as nuon) in a plain sandboxed child after `prelude` (default: loading the barrel).
def plain [ctx: record code: string --prelude: string = $USE_BARREL --vars: record = {}]: nothing -> any {
  let res: record = sandboxed $ctx $"($code) | to nuon --serialize" --prelude $prelude --vars $vars
  if $res.exit_code != 0 { error make --unspanned {msg: $"child failed: ($res.stderr | str trim)"} }
  $res.stdout | lines | last | from nuon
}

# Run `code` like `plain`, in a child started with `--login` (and `--interactive` unless `--not-interactive`).
def login [ctx: record code: string --prelude: string = $USE_BARREL --vars: record = {} --not-interactive]: nothing -> any {
  let flags: list<string> = if $not_interactive { [--login] } else { [--login --interactive] }
  let vars: record = {
    HOME: $ctx.home
    XDG_CONFIG_HOME: $ctx.config
    XDG_DATA_HOME: $ctx.data
    XDG_CACHE_HOME: $ctx.cache
    XDG_STATE_HOME: $ctx.state
  } | merge $vars
  let program: string = $"($prelude)\n($code) | to nuon --serialize"
  let res: record = with-env $vars {
    '' | ^$nu.current-exe --no-config-file ...$flags --include-path=($ROOT) --commands $program | complete
  }
  if $res.exit_code != 0 { error make --unspanned {msg: $"login child failed: ($res.stderr | str trim)"} }
  $res.stdout | lines | last | from nuon
}

def need-linux []: nothing -> nothing {
  if $nu.os-info.name != linux { skip 'the windows loader only runs on Linux (WSL)' }
}

# ——— surface ——————————————————————————————————————————————————————————————————

def "test barrel exposes the module namespaces" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list<string> = plain $ctx '(scope commands | get name) ++ (scope aliases | get name)'
    let expected: list<string> = [
      'pman upgrade' 'pman history' 'link bin' 'reload' 'edit' 'path rejoin' 'path truncate'
      'proj scan' 'track focus' 'time' 'todo' 'hook add' 'conf vars' 'conf machine-config' 'env' 'env dotenv' 'error raise'
      'alarm' 'alarm set' 'alarm unset' 'alarm list' 'alarm show'
      'mods' 'mods define' 'mods edit' 'mods list' 'mods refresh'
      'elevate' 'elevate sh' 'elevate with-auth'
      'win env' 'pwsh' 'into completions' 'into spans'
    ]
    let missing: list<string> = $expected | where $it not-in $names
    assert equal $missing [] 'every expected command is exposed'
  }
}

def "test barrel exposes the library constants" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = plain $ctx '{lib: $NU_LIB_DIRS plugins: $NU_PLUGIN_DIRS}'
    assert equal ($r.lib | first) $ROOT 'NU_LIB_DIRS starts with the library root'
    assert ($r.plugins | is-not-empty) 'NU_PLUGIN_DIRS'
  }
}

def "test elevate is not flattened" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list<string> = plain $ctx "scope commands | where name in [sh with-auth] and type != built-in | get name"
    assert equal $names [] 'no bare `sh` or `with-auth` shadows /bin/sh'
  }
}

def "test flattened names do not shadow builtins" []: nothing -> nothing {
  with-sandbox {|ctx|
    let builtins: list<string> = scope commands | where type in [built-in keyword plugin] | get name
    let added: list<string> = plain $ctx '(scope commands | where type == custom | get name) ++ (scope aliases | get name)'
    assert equal ($added | where $it in $builtins) [] 'no custom command or alias takes a builtin name'
  }
}

def "test local variants have no stray main" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list<string> = plain $ctx "scope commands | where name =~ '^(alarm|mods) (local|mod|alarm|mods)$' | get name"
    assert equal $names [] 'a re-exported main would show up as <module> local/mod'
  }
}

def "test mods and alarm mains delegate" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = plain $ctx '{mods: (mods | columns) alarm: (alarm | describe)}'
    assert equal $r.mods [name module_id] 'mods returns the tracked modules'
    assert ($r.alarm =~ '^(list|table|nothing)') $'alarm lists the alarms: ($r.alarm)'
  }
}

def "test mods main passes its input on" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = plain $ctx $"{name: sbbarrel definition: {|| export def q [] { 1 } } directory: '($ctx.code)'} | mods"
    assert equal $file ($ctx.code | path join sbbarrel mod.nu) 'a details record defines a module'
  }
}

# ——— environment ——————————————————————————————————————————————————————————————

def "test plain shells get the missing lib dirs only" []: nothing -> nothing {
  with-sandbox {|ctx|
    let prelude: string = $"$env.NU_LIB_DIRS = ['($ROOT)' /sbbarrel/existing]\n($USE_BARREL)"
    let r: record = plain $ctx '{dirs: $env.NU_LIB_DIRS consts: $NU_LIB_DIRS}' --prelude $prelude
    assert equal ($r.dirs | take 2) [$ROOT /sbbarrel/existing] 'existing entries keep their order'
    assert equal ($r.dirs | length) ($r.dirs | uniq | length) 'the library root is not added twice'
    assert ($r.consts | all {|d| $d in $r.dirs }) 'every library dir is present'
  }
}

def "test plain shells skip the login loaders" []: nothing -> nothing {
  with-sandbox {|ctx|
    let before: record = plain $ctx '$env | select NU_PLUGIN_DIRS' --prelude ''
    let r: record = plain $ctx '{plugins: $env.NU_PLUGIN_DIRS home: $env.mods_home? hooks: ($env.config.hooks.pre_execution? | default [] | length)}'
    assert equal $r.plugins $before.NU_PLUGIN_DIRS 'conf is not loaded outside login shells'
    assert equal [$r.home $r.hooks] [null 0] 'mods is not loaded outside interactive login shells'
  }
}

def "test windows loader splits PATH on linux" []: nothing -> nothing {
  need-linux
  with-sandbox {|ctx|
    let path: string = ['/mnt/c/sbbarrel/win' ...$env.PATH] | str join (char esep)
    let r: record = plain $ctx '{win: $env.WINPATH path: $env.PATH}' --vars {PATH: $path}
    assert equal $r.win ['/mnt/c/sbbarrel/win'] 'Windows entries move to WINPATH'
    assert not ('/mnt/c/sbbarrel/win' in $r.path) 'and leave PATH'
  }
}

def "test login shells load conf" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = login $ctx '{plugins: $env.NU_PLUGIN_DIRS vendor: (conf machine-config vendor --host other).plugins home: $env.mods_home?}' --not-interactive
    assert ($r.vendor | all {|d| $d in $r.plugins }) 'the vendor plugin dirs are loaded'
    assert equal $r.home null 'mods needs an interactive shell too'
  }
}

def "test interactive login shells load mods" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = login $ctx '{home: $env.mods_home hooks: ($env.config.hooks.pre_execution | get name)}'
    assert equal $r.home $ROOT 'mods_home is the first existing lib dir'
    assert equal $r.hooks ['mods::use_or_hide::update-mods-used'] 'the tracking hook is registered'
  }
}

def "test loading the barrel twice changes nothing" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{env: ($env | select NU_LIB_DIRS NU_PLUGIN_DIRS PATH mods_home) hooks: ($env.config.hooks.pre_execution | length)}'
    let once: record = login $ctx $code
    let twice: record = login $ctx $code --prelude $"($USE_BARREL)\n($USE_BARREL)"
    assert equal $twice $once 'every loader is idempotent'
    assert equal ($twice.env.PATH | length) ($twice.env.PATH | uniq | length) 'no duplicate PATH entries'
  }
}
