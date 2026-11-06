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

# A workspace for `proj` under the sandbox, holding one project, `src/sbproj`; returns its root.
def workspace [ctx: record]: nothing -> path {
  let work: path = $ctx.code | path join work
  mkdir ($work | path join src sbproj)
  $work
}

# Whether the kernel is WSL's (the windows loader then runs whatever the environment says).
def wsl-kernel []: nothing -> bool { $nu.os-info.kernel_version =~ '(?i)microsoft' }

# ——— surface ——————————————————————————————————————————————————————————————————

def "test barrel exposes the module namespaces" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list<string> = plain $ctx '(scope commands | get name) ++ (scope aliases | get name)'
    let expected: list<string> = [
      'pman upgrade' 'pman history' 'link bin' 'reload' 'edit' 'path rejoin' 'path truncate'
      'proj scan' 'track focus' 'time' 'todo' 'hook add' 'conf vars' 'conf machine-config' 'env' 'env dotenv' 'env from-bash' 'error raise'
      'alarm' 'alarm set' 'alarm unset' 'alarm list' 'alarm show'
      'mods' 'mods define' 'mods edit' 'mods list' 'mods refresh'
      'elevate' 'elevate sh' 'elevate with-auth'
      'win env' 'pwsh'
      'structure' 'into completions' 'into spans' 'set-completer' 'run-completer'
      'fish-complete' 'fish-complete parse-output' 'carapace-complete' 'carapace-complete runtime-env'
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
    let names: list<string> = plain $ctx "scope commands | where name =~ '^(alarm|mods|completion) (local|mod|alarm|mods|completion)$' | get name"
    assert equal $names [] 'a re-exported main would show up as <module> local/mod'
    let top: list<string> = plain $ctx "scope commands | where name =~ '^(local|mod)( |$)' | get name"
    assert equal $top [] 'nor as local or mod'
  }
}

def "test every local variant is exposed bare and nothing is prefixed" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list<string> = plain $ctx 'scope commands | where type == custom | get name'
    let modules: list<string> = glob ($ROOT | path join * local mod.nu) | each { path dirname --num-levels 2 | path basename }
    assert equal ($modules | sort) [alarm completion mods] 'the local variants today'
    let expected: list<string> = [
      alarm 'alarm set' 'alarm unset' 'alarm list' 'alarm show'
      set-completer run-completer 'into completions' fish-complete 'fish-complete parse-output' carapace-complete
      mods 'mods define' 'mods edit' 'mods list' 'mods refresh'
    ]
    assert equal ($expected | where $it not-in $names) [] 'their commands, as bare names'
    assert equal ($names | where $it starts-with 'local ') [] 'no `local …` prefixes anywhere (nothing provides them)'
    assert ('init-local' in $names) 'init-local is part of the surface'
    let loaded: record = plain $ctx '{libs: ($env.NU_LIB_DIRS | length) consts: ($NU_LIB_DIRS | length)}'
    assert ($loaded.libs > 3 and $loaded.consts > 0) 'the barrel ran its environment set-up and exports the constants'
  }
}

def "test the alarm and mods wrappers delegate" []: nothing -> nothing {
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
    let code: string = '{
      plugins: $env.NU_PLUGIN_DIRS
      home: $env.mods_home?
      hooks: ($env.config.hooks.pre_execution? | default [] | length)
      pwd: ($env.config.hooks.env_change?.PWD? | default [] | length)
      carapace: ($env | columns | where $it starts-with CARAPACE)
      scanned: (proj meta)
    }'
    let r: record = plain $ctx $code --vars {WORK: (workspace $ctx)}
    assert equal $r.plugins $before.NU_PLUGIN_DIRS 'conf is not loaded outside login shells'
    assert equal [$r.home $r.hooks] [null 0] 'mods is not loaded outside interactive login shells'
    assert equal $r.carapace [] 'nor are the completers'
    assert equal $r.pwd 0 'nor the track hooks'
    assert equal $r.scanned {} 'nor does proj scan WORK'
  }
}

def "test windows loader splits PATH under WSL" []: nothing -> nothing {
  with-sandbox {|ctx|
    let path: string = ['/mnt/c/sbbarrel/win' ...$env.PATH] | str join (char esep)
    let r: record = plain $ctx '{win: $env.WINPATH path: $env.PATH}' --vars {PATH: $path WSL_DISTRO_NAME: sbdistro}
    assert equal $r.win ['/mnt/c/sbbarrel/win'] 'Windows entries move to WINPATH'
    assert not ('/mnt/c/sbbarrel/win' in $r.path) 'and leave PATH'
  }
}

def "test windows loader follows the kernel without WSL_DISTRO_NAME" []: nothing -> nothing {
  with-sandbox {|ctx|
    let prelude: string = $"hide-env --ignore-errors WSL_DISTRO_NAME\n($USE_BARREL)"
    let r: record = plain $ctx '{win: $env.WINPATH? distro: $env.WSL_DISTRO_NAME?}' --prelude $prelude
    assert equal ($r.win != null) (wsl-kernel) 'loaded exactly when the kernel release names Microsoft'
    assert equal ($r.distro != null) (wsl-kernel) 'which then sets WSL_DISTRO_NAME'
  }
}

def "test login shells load conf" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = login $ctx '{plugins: $env.NU_PLUGIN_DIRS vendor: (conf machine-config vendor --host other).plugins home: $env.mods_home?}' --not-interactive
    assert ($r.vendor | all {|d| $d in $r.plugins }) 'the vendor plugin dirs are loaded'
    assert equal $r.home null 'mods needs an interactive shell too'
  }
}

def "test interactive login shells load the completers" []: nothing -> nothing {
  with-sandbox {|ctx|
    let vars: list<string> = login $ctx '$env | columns | where $it starts-with CARAPACE'
    assert ($vars | is-not-empty) 'completion/local sets its CARAPACE_* variables'
  }
}

def "test interactive login shells load mods" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = login $ctx '{home: $env.mods_home hooks: ($env.config.hooks.pre_execution | get name)}'
    assert equal $r.home $ROOT 'mods_home is the first existing lib dir'
    assert ('mods::use_or_hide::update-mods-used' in $r.hooks) 'the tracking hook is registered'
  }
}

def "test interactive login shells load track" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = login $ctx '{pre: ($env.config.hooks.pre_execution | get name) pwd: ($env.config.hooks.env_change.PWD | get name)}'
    assert ('track::sync' in $r.pre) 'the sync hook runs before each command'
    assert equal $r.pwd ['track::focus'] 'the focus hook follows the directory'
  }
}

def "test interactive login shells scan the workspace" []: nothing -> nothing {
  with-sandbox {|ctx|
    let work: path = workspace $ctx
    assert equal (login $ctx 'proj meta | get total_count' --vars {WORK: $work}) 1 'proj registers the workspace'
  }
  with-sandbox {|ctx|
    assert equal (login $ctx 'proj meta') {} 'nothing is scanned without WORK'
  }
}

def "test non-interactive login shells skip proj and track" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{pre: ($env.config.hooks.pre_execution? | default [] | length) scanned: (proj meta)}'
    let r: record = login $ctx $code --vars {WORK: (workspace $ctx)} --not-interactive
    assert equal $r {pre: 0 scanned: {}} 'both need an interactive login shell'
  }
}

def "test loading the barrel twice changes nothing" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{
      env: ($env | select NU_LIB_DIRS NU_PLUGIN_DIRS PATH mods_home DIRS_LIST)
      hooks: {pre: ($env.config.hooks.pre_execution | get name) pwd: ($env.config.hooks.env_change.PWD | get name)}
      projects: (proj list | get name)
    }'
    let vars: record = {WORK: (workspace $ctx)}
    let once: record = login $ctx $code --vars $vars
    let twice: record = login $ctx $code --prelude $"($USE_BARREL)\n($USE_BARREL)" --vars $vars
    assert equal $twice $once 'every loader is idempotent'
    assert equal ($twice.env.PATH | length) ($twice.env.PATH | uniq | length) 'no duplicate PATH entries'
    assert equal $twice.projects [sbproj] 'the workspace is registered once'
  }
}

# ——— prelude.nu and init-local ————————————————————————————————————————————————

# The line every generated file carries (the root exactly as `init-local` writes it; `to nuon` is not a parse-time
# command, so this is a def, not a const).
def prelude-line []: nothing -> string { $"use ($ROOT | to nuon) *" }

def "test init-local writes the autoload file once and keeps edits" []: nothing -> nothing {
  with-sandbox {|ctx|
    let expected: path = $ctx.config | path join nushell autoload nu-lib.nu
    let first: record = plain $ctx 'init-local'
    assert equal $first {path: $expected action: written} 'written into the first user autoload directory'
    assert equal (open --raw $expected | lines | slice 1..) [(prelude-line)] 'one `use` line after a one-line header'
    assert equal (plain $ctx 'init-local').action unchanged 'the same content is left alone'
    "# edited by hand\n" | save --append $expected
    assert equal (plain $ctx 'init-local').action kept 'different content is kept'
    assert str contains (open --raw $expected) 'edited by hand' 'and really untouched'
    assert equal (plain $ctx 'init-local --force').action overwritten '--force replaces it'
    assert equal (open --raw $expected | lines | slice 1..) [(prelude-line)] 'with the generated content'
  }
}

def "test init-local path flag" []: nothing -> nothing {
  with-sandbox {|ctx|
    let target: path = $ctx.code | path join elsewhere boot.nu
    let r: record = plain $ctx $"init-local --path ($target | to nuon)"
    assert equal $r {path: $target action: written} 'writes where --path says, creating the directory'
    assert equal (open --raw $target | lines | slice 1..) [(prelude-line)] 'same content'
  }
}

def "test the generated file gives an interactive login shell the bare local variants" []: nothing -> nothing {
  with-sandbox {|ctx|
    let target: path = $ctx.code | path join nu-lib.nu
    plain $ctx $"init-local --path ($target | to nuon)" | ignore
    let probe: string = '{
      alarm: (scope commands | where name == "alarm set" | is-not-empty)
      mods: (scope commands | where name == "mods edit" | is-not-empty)
      completer: (scope commands | where name == "set-completer" | is-not-empty)
      prefixed: (scope commands | where name starts-with "local " | length)
      pman: (scope commands | where name == "pman upgrade" | is-not-empty)
      libs: ($env.NU_LIB_DIRS | length)
      carapace: ($env.CARAPACE_BRIDGES? | is-not-empty)
    }'
    let r: record = login $ctx $probe --prelude $"source ($target | to nuon)"
    assert ($r.alarm and $r.mods and $r.completer) 'the local variants are bare names'
    assert equal $r.prefixed 0 'no `local …` names reach completions'
    assert $r.pman 'the rest of the surface is there'
    assert ($r.libs > 3 and $r.carapace) 'the environment set-up ran'
  }
}
