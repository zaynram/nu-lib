# `conf` and `conf/machine.nu`: `test _tests/suites/conf.nu`.
#
# `machine-config`'s defaults are parse-time constants derived from `$nu.*`, so they follow the test child's
# sandboxed HOME/XDG directories, and its config directory holds no override file. Override files are written into
# a `with-sandbox` tree and named with `--file` or `NU_MACHINE_CONFIG`; tests of the default location (and of errors
# that make `use conf` itself fail) run in a `sandboxed` grandchild whose HOME and XDG directories point into that
# tree, so the real home is never touched even with `--no-sandbox`. The example override script
# (`_docs/examples/machine.nu`) sources `~/.profile` through `env from-bash` (needs `bash`).
# nu-lint-ignore-file: missing_output_type
# (helpers return whatever the child or the closure produced)
use conf
use style
use ../mod.nu *

const USER_KEYS: list<string> = [home share cache config state autoload modules binaries scripts]
const VENDOR_KEYS: list<string> = [autoload plugins modules binaries scripts]
const EXAMPLE: path = $ROOT | path join _docs examples machine.nu

# ——— helpers ——————————————————————————————————————————————————————————————————

# Run `code` (its value serialized as nuon) after `use conf` in a sandboxed child; return the complete record
# with `value` parsed from stdout when the child succeeded.
def child [ctx: record code: string --vars: record = {} --prelude: string = 'use conf']: nothing -> record {
  let res: record = sandboxed $ctx $"($code) | to nuon --serialize" --prelude $prelude --vars $vars
  let value: any = if $res.exit_code == 0 { $res.stdout | lines | last | from nuon } else { null }
  $res | insert value $value
}

# As `run`, but return the value and fail with the child's stderr when it exits non-zero.
def value [ctx: record code: string --vars: record = {} --prelude: string = 'use conf']: nothing -> any {
  let res: record = child $ctx $code --vars $vars --prelude $prelude
  if $res.exit_code != 0 { error make --unspanned {msg: $"child failed: ($res.stderr | str trim)"} }
  $res.value
}

def need-bash []: nothing -> nothing {
  if (which bash | is-empty) { skip '`bash` is needed to read ~/.profile' }
}

# Write a fake `~/.profile` into the sandbox home.
def profile [ctx: record ...lines: string]: nothing -> nothing {
  $lines | str join (char newline) | save --force ($ctx.home | path join .profile)
}

# Write an override file into the sandbox and return its path.
def override [ctx: record name: path ...lines: string]: nothing -> path {
  let file: path = $ctx.code | path join $name
  $lines | str join (char newline) | save --force $file
  $file
}

# The error `action` raises, as `{msg code help inner}`; fails when it raises nothing.
def caught [action: closure]: nothing -> record {
  try { do $action; error make --unspanned {msg: 'sbconf: nothing was raised' code: 'sbconf::nothing'} } catch {|e|
    {msg: $e.msg code: $e.details?.code? help: $e.details?.help? inner: ($e.details?.inner? | default [])}
  }
}

# ——— machine-config: defaults ————————————————————————————————————————————————

def "test machine config rejects an unknown mode" []: nothing -> nothing {
  let err: record = caught {|| conf machine-config bogus --no-file }
  assert equal $err.code conf::machine::invalid_argument 'only user and vendor are modes'
  assert ($err.msg =~ 'bogus') $'the mode is named: ($err.msg)'
}

def "test machine config rejects an unknown strategy" []: nothing -> nothing {
  let err: record = caught {|| conf machine-config --no-file --strategy sideways }
  assert equal $err.code conf::machine::invalid_argument 'only overwrite/prepend/append'
}

def "test machine config defaults for an unknown host" []: nothing -> nothing {
  let mc: record = conf machine-config --host other
  assert equal ($mc | columns) $USER_KEYS 'the user schema'
  assert equal $mc.home $nu.home-dir 'home'
  assert equal $mc.share ($nu.data-dir | path dirname) 'share is the data parent'
  assert equal $mc.cache ($nu.cache-dir | path dirname) 'cache is the cache parent'
  assert equal $mc.config ($nu.default-config-dir | path dirname) 'config is the config parent'
  assert equal $mc.state ($nu.home-dir | path join .local state) 'state is the XDG default, not the cache'
  assert equal $mc.autoload ($nu.user-autoload-dirs | first) 'the user autoload directory'
  assert equal ($mc.modules | first) $ROOT 'the library root is the first module directory'
}

def "test machine config vendor defaults for an unknown host" []: nothing -> nothing {
  let mc: record = conf machine-config vendor --host other
  assert equal ($mc | columns) $VENDOR_KEYS 'the vendor schema'
  assert equal $mc.modules ($nu.data-dir | path join modules) 'vendor modules under the data dir'
  assert equal ($mc.plugins | first) ($nu.data-dir | path join plugins (version).version) 'versioned plugin dir first'
}

def "test machine config constants follow the defaults" []: nothing -> nothing {
  let mc: record = conf machine-config --host other
  let vendor: record = conf machine-config vendor --host other
  assert equal $conf.NU_LIB_DIRS [...$mc.modules $vendor.modules] 'user module dirs then the vendor one'
  assert equal $conf.NU_PLUGIN_DIRS $vendor.plugins 'the vendor plugin dirs'
}

def "test machine config os picks the vendor binaries" []: nothing -> nothing {
  let windows: path = $nu.home-dir | path join AppData Local Microsoft WindowsApps
  assert equal (conf machine-config vendor --os windows --no-file).binaries $windows 'Windows Apps on Windows'
  assert equal (conf machine-config vendor --os linux --no-file).binaries /usr/bin '/usr/bin elsewhere'
  assert equal (conf machine-config --os windows --no-file | columns) $USER_KEYS 'the user scope does not depend on the OS'
}

def "test machine config no file is the defaults" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {state: /sbstate}}'
    let defaults: record = conf machine-config --no-file
    assert equal $defaults (conf machine-config --host other) 'without a configured file, --no-file changes nothing'
    assert equal (with-env {NU_MACHINE_CONFIG: $file} { conf machine-config --no-file }) $defaults 'the configured file is ignored'
    let err: record = caught {|| conf machine-config --no-file --file $file }
    assert equal $err.code conf::machine::invalid_argument '--file and --no-file are exclusive'
  }
}

def "test machine config verbose prints the target and the override" []: nothing -> nothing {
  with-sandbox {|ctx|
    let none: record = child $ctx 'conf machine-config --host other --verbose'
    assert ($none.stdout =~ 'host = other') $'the target is printed: ($none.stdout)'
    assert ($none.stdout =~ 'override = none') $'no override is reported: ($none.stdout)'
    let file: path = override $ctx machine.nuon '{strategy: append}'
    let some: record = child $ctx $'conf machine-config --verbose --file ($file)'
    assert ($some.stdout =~ $'override = ($file)') $'the override file is reported: ($some.stdout)'
    assert ($some.stdout =~ 'strategy = append') $'the effective strategy is reported: ($some.stdout)'
  }
}

# ——— machine-config: override file ———————————————————————————————————————————

def "test machine config nuon override merges over the defaults" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {state: /sbstate modules: [/sbmods]} vendor: {scripts: /sbvendor/scripts}}'
    let mc: record = conf machine-config --file $file
    assert equal ($mc | columns) $USER_KEYS 'the user schema'
    assert equal $mc.state /sbstate 'a scalar from the file'
    assert equal $mc.modules [/sbmods] 'a list from the file replaces the default'
    assert equal $mc.home $nu.home-dir 'keys the file does not set keep their defaults'
    let vendor: record = conf machine-config vendor --file $file
    assert equal $vendor.scripts /sbvendor/scripts 'the vendor partial applies to the vendor scope'
    assert equal $vendor.modules ($nu.data-dir | path join modules) 'and keeps the other defaults'
  }
}

def "test machine config strategy combines lists" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {modules: [/sbmods]}}'
    let defaults: list = (conf machine-config --no-file).modules
    assert equal (conf machine-config --file $file).modules [/sbmods] 'overwrite replaces the list'
    assert equal (conf machine-config --file $file --strategy prepend).modules [/sbmods ...$defaults] 'prepend puts the machine values first'
    assert equal (conf machine-config --file $file --strategy append).modules [...$defaults /sbmods] 'append adds them after the defaults'
  }
}

def "test machine config file strategy is the default and the flag wins" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{strategy: append user: {modules: [/sbmods]}}'
    let defaults: list = (conf machine-config --no-file).modules
    assert equal (conf machine-config --file $file).modules [...$defaults /sbmods] 'the file sets the strategy'
    assert equal (conf machine-config --file $file --strategy overwrite).modules [/sbmods] '--strategy overrides it'
    let bad: path = override $ctx bad.nuon '{strategy: sideways}'
    let err: record = caught {|| conf machine-config --file $bad }
    assert equal $err.code conf::machine::check::invalid_argument 'an unknown strategy in the file is invalid'
    assert ($err.msg =~ 'strategy') $'the key is named: ($err.msg)'
  }
}

def "test machine config null values leave the defaults" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {state: null modules: null}}'
    let mc: record = conf machine-config --file $file
    assert equal $mc (conf machine-config --no-file) 'null means unset'
  }
}

def "test machine config nu override runs and merges" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nu 'def main []: nothing -> record {' '  {user: {state: ($nu.home-dir | path join sbstate)} vendor: {modules: "/sbvendor/modules"}}' '}'
    let mc: record = conf machine-config --file $file
    assert equal $mc.state ($nu.home-dir | path join sbstate) 'the script computed the value in a child with the same home'
    assert equal ($mc | columns) $USER_KEYS 'the user schema'
    assert equal (conf machine-config vendor --file $file).modules /sbvendor/modules 'the vendor partial'
  }
}

def "test machine config nu override sees the library and no override of its own" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nu 'use conf' 'def main []: nothing -> record {' '  {user: {state: ((conf machine-config).state | path join sb) cache: ($NU_LIB_DIRS | first)}}' '}'
    let mc: record = with-env {NU_MACHINE_CONFIG: $file} { conf machine-config }
    assert equal $mc.state ($nu.home-dir | path join .local state sb) 'inside the script, machine-config returns the defaults instead of running the script again'
    assert equal $mc.cache $ROOT 'the library root is the first include path'
  }
}

def "test machine config nu override passes its stderr on" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nu 'def main []: nothing -> record { print --stderr sbnote; {user: {state: /sbstate}} }'
    let res: record = child $ctx $'conf machine-config --file ($file)'
    assert equal $res.exit_code 0 $'the script succeeded: ($res.stderr)'
    assert ($res.stderr =~ 'sbnote') $'its stderr is printed: ($res.stderr)'
    assert equal $res.value.state /sbstate 'and its record is used'
  }
}

def "test machine config env names the override file" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {state: /sbstate}}'
    assert equal (with-env {NU_MACHINE_CONFIG: $file} { conf machine-config }).state /sbstate 'NU_MACHINE_CONFIG names the file'
    let other: path = override $ctx other.nuon '{user: {state: /sbother}}'
    assert equal (with-env {NU_MACHINE_CONFIG: $file} { conf machine-config --file $other }).state /sbother '--file beats it'
    let missing: record = caught {|| with-env {NU_MACHINE_CONFIG: '/sbconf/none.nuon'} { conf machine-config } }
    assert equal $missing.code conf::machine::override-path::not_found 'a named file must exist'
    assert ($missing.msg =~ '/sbconf/none.nuon') $'the path is named: ($missing.msg)'
  }
}

def "test machine config finds the file in the config directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.config | path join nushell
    mkdir $dir
    '{user: {state: /sbstate}}' | save --force ($dir | path join machine.nuon)
    let defaults: record = value $ctx 'conf machine-config --no-file'
    assert equal (value $ctx 'conf machine-config').state /sbstate 'machine.nuon in the config directory is loaded'
    assert equal (value $ctx 'conf machine-config' --vars {NU_MACHINE_CONFIG: ''}) $defaults 'an empty NU_MACHINE_CONFIG means no file'
    assert ($ROOT in (value $ctx 'conf vars | get NU_LIB_DIRS')) 'conf vars still includes the library root'
    rm ($dir | path join machine.nuon)
    'def main []: nothing -> record { {user: {state: "/sbscript"}} }' | save --force ($dir | path join machine.nu)
    assert equal (value $ctx 'conf machine-config').state /sbscript 'machine.nu in the config directory is run'
  }
}

def "test machine config both files is a conflict" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.config | path join nushell
    mkdir $dir
    '{user: {state: /sbstate}}' | save --force ($dir | path join machine.nuon)
    'def main []: nothing -> record { {user: {state: "/sbscript"}} }' | save --force ($dir | path join machine.nu)
    let res: record = child $ctx 'conf machine-config'
    assert ($res.exit_code != 0) 'the conflict is an error for an explicit call'
    assert ($res.stderr =~ 'conf::machine::override-path::conflict') $'the conflict code: ($res.stderr)'
    assert ($res.stderr =~ 'machine.nuon' and $res.stderr =~ 'machine.nu\b') $'both files are named: ($res.stderr)'
    assert equal (value $ctx 'conf machine-config' --vars {NU_MACHINE_CONFIG: ($dir | path join machine.nu)}).state /sbscript 'naming one resolves it'
  }
}

def "test a broken override is reported by use conf and the defaults are loaded" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.config | path join nushell
    mkdir $dir
    '{vendor: {plugins: "not-a-list"}}' | save --force ($dir | path join machine.nuon)
    let res: record = child $ctx '$env.NU_PLUGIN_DIRS'
    assert equal $res.exit_code 0 $'`use conf` survives a broken override: ($res.stderr)'
    assert ($res.stderr =~ 'ignored, using the defaults' and $res.stderr =~ 'plugins') $'the cause is reported: ($res.stderr)'
    let defaults: list<string> = value $ctx '(conf machine-config vendor --no-file).plugins'
    assert equal ($res.value | where $it in $defaults) $defaults 'the default plugin dirs are loaded'
    assert equal (child $ctx 'conf machine-config vendor').exit_code 1 'an explicit call still raises'
  }
}

def "test the fallback warning is coloured only when colours are on" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.config | path join nushell
    mkdir $dir
    '{vendor: {plugins: "not-a-list"}}' | save --force ($dir | path join machine.nuon)
    let plain: record = child $ctx 'null'
    assert equal $plain.exit_code 0 $'`use conf` survives: ($plain.stderr)'
    assert ($plain.stderr =~ 'ignored, using the defaults') 'the warning is printed'
    assert not ($plain.stderr =~ '\e\[') $'no escape sequences without a terminal: ($plain.stderr)'
    # The export-env block runs when `use conf` executes, after the assignment.
    let styled: record = child $ctx 'null' --prelude '$env.config.use_ansi_coloring = true; use conf'
    assert equal $styled.exit_code 0 $'`use conf` survives: ($styled.stderr)'
    assert str contains $styled.stderr ('conf: the machine override file was ignored, using the defaults:' | style paint yellow --colors=true) 'the warning is yellow when colours are on'
  }
}

def "test a failing override script is reported with its cause by use conf" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.config | path join nushell
    mkdir $dir
    "def main []: nothing -> record { if true { error make --unspanned {msg: 'SBCONF_CAUSE: the profile is missing'} }; {} }" | save --force ($dir | path join machine.nu)
    let res: record = child $ctx '$env.NU_PLUGIN_DIRS'
    assert equal $res.exit_code 0 $'`use conf` survives a failing script: ($res.stderr)'
    assert ($res.stderr =~ 'SBCONF_CAUSE') $"the script's own message is in the warning: ($res.stderr)"
  }
}

def "test machine config invalid shape names the file and every violation" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {home: 5 typo: 1} extra: 2}'
    let err: record = caught {|| conf machine-config --file $file }
    assert equal $err.code conf::machine::check::invalid_argument 'the validation code'
    assert ($err.msg =~ $file) $'the file is named: ($err.msg)'
    assert ($err.msg =~ '\$\.user\.home has type int; expected string') $'the first failure is the message: ($err.msg)'
    assert ($err.help =~ 'foreign-key: .*\$\.user\.typo') $'undeclared keys are listed: ($err.help)'
    assert ($err.help =~ '\$\.extra') $'at the root too: ($err.help)'
    let list: path = override $ctx list.nuon '{user: {modules: [1 2]}}'
    assert ((caught {|| conf machine-config --file $list }).msg =~ 'expected list<string>') 'list keys hold strings'
  }
}

def "test machine config a file that is not a record is invalid" []: nothing -> nothing {
  with-sandbox {|ctx|
    let list: path = override $ctx machine.nuon '[1 2]'
    let err: record = caught {|| conf machine-config --file $list }
    assert equal $err.code conf::machine::load::invalid_argument 'the load code'
    assert ($err.msg =~ 'must be a record, not list') $'the shape is named: ($err.msg)'
    let broken: path = override $ctx broken.nuon '{user: '
    let malformed: record = caught {|| conf machine-config --file $broken }
    assert equal $malformed.code conf::machine::load::invalid_argument 'malformed nuon is invalid'
    assert ($malformed.msg =~ 'not valid nuon') $'the cause is named: ($malformed.msg)'
    assert ($malformed.inner | is-not-empty) 'the parse error is the inner error'
    let other: path = override $ctx machine.toml 'a = 1'
    let unsupported: record = caught {|| conf machine-config --file $other }
    assert equal $unsupported.code conf::machine::load::invalid_argument 'other extensions are invalid'
    assert ($unsupported.msg =~ 'expected .nuon or .nu') $'the supported forms are named: ($unsupported.msg)'
  }
}

def "test machine config a failing script is an external failure with its stderr" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nu 'def main []: nothing -> record { ls /sbnone/zz | first | {} }'
    let err: record = caught {|| conf machine-config --file $file }
    assert equal $err.code conf::machine::load::external_failure 'the external_failure code'
    assert ($err.msg =~ $file) $'the script is named: ($err.msg)'
    assert ($err.help =~ '/sbnone/zz') $'the child stderr is the advice: ($err.help)'
  }
}

def "test machine config a script that does not return a record is invalid" []: nothing -> nothing {
  with-sandbox {|ctx|
    let list: path = override $ctx machine.nu 'def main []: nothing -> list { [1 2] }'
    let err: record = caught {|| conf machine-config --file $list }
    assert equal $err.code conf::machine::load::invalid_argument 'the load code'
    assert ($err.msg =~ 'must be a record, not list') $'the shape is named: ($err.msg)'
    let noisy: path = override $ctx noisy.nu 'def main []: nothing -> record { print junk; {user: {state: "/sbstate"}} }'
    let printed: record = caught {|| conf machine-config --file $noisy }
    assert equal $printed.code conf::machine::load::invalid_argument 'stdout other than the record is invalid'
    assert ($printed.msg =~ 'printed something other than its record') $'the cause is named: ($printed.msg)'
  }
}

def "test machine config with beats the file" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = override $ctx machine.nuon '{user: {state: /sbfile modules: [/sbfile]}}'
    let mc: record = conf machine-config --file $file --with {user: {state: /sbwith}}
    assert equal $mc.state /sbwith '--with wins over the file'
    assert equal $mc.modules [/sbfile] 'keys --with does not set come from the file'
    assert equal (conf machine-config --no-file --with {user: {state: /sbwith}}).state /sbwith '--with applies without a file'
    let defaults: list = (conf machine-config --no-file).modules
    let appended: record = conf machine-config --no-file --with {strategy: append user: {modules: [/sbwith]}}
    assert equal $appended.modules [...$defaults /sbwith] 'its strategy key is the default strategy'
    assert equal (conf machine-config vendor --no-file --with {user: {state: /sbwith}} | columns) $VENDOR_KEYS 'the user partial does not touch the vendor scope'
  }
}

def "test machine config with is validated" []: nothing -> nothing {
  let err: record = caught {|| conf machine-config --no-file --with {modules: [/sbwith]} }
  assert equal $err.code conf::machine::check::invalid_argument 'the same shape as the file'
  assert ($err.msg =~ '--with' and $err.msg =~ '\$\.modules') $'the source and the key are named: ($err.msg)'
}

# ——— the example override script ——————————————————————————————————————————————

# Run `action` with the sandbox home as HOME, so the script reads the sandbox `~/.profile`.
def at-home [ctx: record vars: record action: closure]: nothing -> any {
  with-env ({HOME: $ctx.home} | merge $vars) $action
}

def "test example script reads the profile" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    profile $ctx 'export XDG_DATA_DIR="$HOME/d"' 'export XDG_CONFIG_DIR="$HOME/c"' 'export XDG_DOWNLOAD_DIR="$HOME/dl"' 'export PATH="/sbconf/profile/bin:$PATH"'
    let mc: record = at-home $ctx {WORK: /sbwork} {|| conf machine-config --file $EXAMPLE }
    let d: path = $ctx.home | path join d
    assert equal ($mc | columns | sort) ($USER_KEYS | sort) 'XDG variables map to schema keys; unknown ones are dropped'
    assert equal $mc.share $d 'XDG_DATA_DIR sets share'
    assert equal $mc.config ($ctx.home | path join c) 'XDG_CONFIG_DIR sets config'
    assert equal $mc.modules [$ROOT /sbwork/ext] 'modules from the library root and WORK'
    assert equal $mc.scripts [/sbwork/bin ($d | path join nupm scripts)] 'scripts from WORK and the data dir'
    assert ('/sbconf/profile/bin' in $mc.binaries) 'the profile PATH is merged into binaries'
    assert equal ($mc.binaries | take 1) [/usr/bin] 'system binaries come first'
    assert ($d | path join pnpm | $in in $mc.binaries) 'data-dir tool directories are included'
  }
}

def "test example script takes only the PATH entries of the profile" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    profile $ctx 'export PATH="/a:$PATH"'
    let path: list<string> = $env.PATH | prepend /sbconf/inherited
    let mc: record = at-home $ctx {WORK: /sbwork PATH: $path} {|| conf machine-config --file $EXAMPLE }
    assert ('/a' in $mc.binaries) 'the entry the profile adds'
    assert ('/sbconf/inherited' not-in $mc.binaries) 'not the PATH the shell inherited'
  }
}

def "test example script takes WORK from the profile" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    profile $ctx 'export WORK=/sbprofile-work'
    let mc: record = at-home $ctx {} {|| conf machine-config --file $EXAMPLE }
    assert equal ($mc.modules | last) /sbprofile-work/ext 'WORK set by the profile is used'
  }
}

def "test example script without a profile fails naming it" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    let err: record = at-home $ctx {WORK: /sbwork} {|| caught {|| conf machine-config --file $EXAMPLE } }
    assert equal $err.code conf::machine::load::external_failure 'a failing script fails machine-config'
    assert ($err.help =~ '\.profile') $'the missing profile is reported: ($err.help)'
  }
}

def "test example script without WORK fails naming it" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    profile $ctx 'export XDG_DATA_DIR="$HOME/d"'
    let err: record = at-home $ctx {} {|| caught {|| conf machine-config --file $EXAMPLE } }
    assert equal $err.code conf::machine::load::external_failure 'a failing script fails machine-config'
    assert ($err.help =~ 'WORK is not set') $'the cause is reported: ($err.help)'
  }
}

def "test example script vendor scope follows NUPM_HOME" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    profile $ctx 'export WORK=/sbwork'
    let mc: record = at-home $ctx {NUPM_HOME: /nupm} {|| conf machine-config vendor --file $EXAMPLE }
    assert equal [$mc.modules $mc.scripts $mc.binaries] [/nupm/modules /nupm/scripts /usr/bin] 'NUPM_HOME layout'
    assert equal ($mc | columns) $VENDOR_KEYS 'the vendor schema'
    let nupm: path = $nu.data-dir | path dirname | path join nupm
    let default: record = at-home $ctx {} {|| conf machine-config vendor --file $EXAMPLE }
    assert equal $default.modules ($nupm | path join modules) 'without NUPM_HOME, nupm next to the nushell data dir'
  }
}

def "test example script strategy combines lists" []: nothing -> nothing {
  need-bash
  with-sandbox {|ctx|
    profile $ctx 'export WORK=/sbwork'
    let defaults: list = (conf machine-config --no-file).modules
    let over: list = at-home $ctx {} {|| (conf machine-config --file $EXAMPLE).modules }
    let prepend: list = at-home $ctx {} {|| (conf machine-config --file $EXAMPLE --strategy prepend).modules }
    let append: list = at-home $ctx {} {|| (conf machine-config --file $EXAMPLE --strategy append).modules }
    assert equal $over [$ROOT /sbwork/ext] 'overwrite replaces the list'
    assert equal $prepend ([$ROOT /sbwork/ext] ++ $defaults | uniq) 'prepend puts the machine values first'
    assert equal $append ($defaults ++ [/sbwork/ext] | uniq) 'append adds them after the defaults'
  }
}

# ——— conf vars ————————————————————————————————————————————————————————————————

def "test vars returns the user scope variables" []: nothing -> nothing {
  let v: record = conf vars
  assert equal ($v | columns) [NU_LIB_DIRS PATH] 'user scope variables'
  assert ($ROOT in $v.NU_LIB_DIRS) 'the scope directories are included'
}

def "test vars keeps the positions of entries already present" []: nothing -> nothing {
  $env.NU_LIB_DIRS = [/sbconf/existing $ROOT]
  let v: record = conf vars
  assert equal ($v.NU_LIB_DIRS | last 2) [/sbconf/existing $ROOT] 'present entries keep their order'
  assert equal ($v.NU_LIB_DIRS | where $it == $ROOT | length) 1 'nothing is duplicated'
  let again: record = with-env {NU_LIB_DIRS: $v.NU_LIB_DIRS PATH: $v.PATH} { conf vars }
  assert equal $again $v 'applying the result again changes nothing'
}

def "test vars vendor adds plugin dirs" []: nothing -> nothing {
  assert equal (conf vars --vendor | columns | sort) [NU_LIB_DIRS NU_PLUGIN_DIRS PATH] 'vendor scope variables'
}

def "test vars keeps existing entries after the scope" []: nothing -> nothing {
  $env.NU_LIB_DIRS = [/sbconf/existing]
  $env.PATH = [/sbconf/bin ...$env.PATH]
  let v: record = conf vars
  assert equal ($v.NU_LIB_DIRS | last) /sbconf/existing 'existing lib dirs are kept, after the scope'
  assert ('/sbconf/bin' in $v.PATH) 'existing PATH entries are kept'
  assert equal ($v.PATH | length) ($v.PATH | uniq | length) 'no duplicates'
}

def "test vars includes piped input and with without loading" []: nothing -> nothing {
  let v: record = {SBCONF_PIPED: 1 NU_LIB_DIRS: [/sbconf/first]} | conf vars --with {SBCONF_WITH: 2}
  assert equal [$v.SBCONF_PIPED $v.SBCONF_WITH] [1 2] 'piped and --with variables are returned'
  assert equal ($v.NU_LIB_DIRS | first) /sbconf/first 'piped list entries come first'
  assert ($ROOT in $v.NU_LIB_DIRS) 'the scope directories are included'
}

def "test vars with replaces scope values" []: nothing -> nothing {
  assert equal (conf vars --with {NU_LIB_DIRS: [/sbconf/only]}).NU_LIB_DIRS [/sbconf/only] '--with wins'
}

def "test vars load sets the variables" []: nothing -> nothing {
  $env.NU_LIB_DIRS = [/sbconf/existing]
  let out: any = conf vars --load --with {SBCONF_LOADED: yes}
  assert equal $out null 'loading returns nothing'
  assert equal $env.SBCONF_LOADED 'yes' '--with variables are loaded'
  assert equal ($env.NU_LIB_DIRS | first) $ROOT 'the scope directories are loaded'
  assert equal ($env.NU_LIB_DIRS | last) /sbconf/existing 'without dropping existing ones'
}

def "test vars load is idempotent" []: nothing -> nothing {
  conf vars --load
  let once: record = $env | select NU_LIB_DIRS PATH
  conf vars --load
  assert equal ($env | select NU_LIB_DIRS PATH) $once 'loading again changes nothing'
}

def "test vars load return returns the record" []: nothing -> nothing {
  assert equal (conf vars --load --return | columns) [NU_LIB_DIRS PATH] '--return with --load'
}

# ——— export-env ———————————————————————————————————————————————————————————————

def "test use conf adds library dirs and keeps existing ones" []: nothing -> nothing {
  with-sandbox {|ctx|
    let prelude: string = '$env.NU_LIB_DIRS = [/sbconf/existing]; use conf'
    let v: record = value $ctx '$env | select NU_LIB_DIRS NU_PLUGIN_DIRS' --prelude $prelude
    let consts: record = value $ctx '{lib: $conf.NU_LIB_DIRS plugins: $conf.NU_PLUGIN_DIRS}' --prelude 'use conf'
    assert ('/sbconf/existing' in $v.NU_LIB_DIRS) 'existing lib dirs survive `use conf`'
    assert ($consts.lib | all {|d| $d in $v.NU_LIB_DIRS }) 'every library dir is added'
    assert equal ($v.NU_LIB_DIRS | first) $ROOT 'the library root takes precedence'
    assert ($consts.plugins | all {|d| $d in $v.NU_PLUGIN_DIRS }) 'plugin dirs are added'
  }
}

def "test use conf twice changes nothing" []: nothing -> nothing {
  with-sandbox {|ctx|
    let once: record = value $ctx '$env | select NU_LIB_DIRS NU_PLUGIN_DIRS PATH'
    let twice: record = value $ctx '$env | select NU_LIB_DIRS NU_PLUGIN_DIRS PATH' --prelude 'use conf; use conf'
    assert equal $twice $once 'the export-env is idempotent'
  }
}

# ——— conf dir —————————————————————————————————————————————————————————————————

def "test dir without target returns the scope" []: nothing -> nothing {
  assert equal (conf dir | columns) $USER_KEYS 'the user scope'
  assert equal (conf dir --vendor | columns) $VENDOR_KEYS 'the vendor scope'
}

def "test dir return resolves case insensitively" []: nothing -> nothing {
  assert equal (conf dir SHARE --return) (conf machine-config).share 'target names ignore case'
}

def "test dir changes directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    let pwd: path = value $ctx 'conf dir home; $env.PWD'
    assert equal $pwd $ctx.home 'dir navigates to the directory'
  }
}

def "test dir unknown target raises" []: nothing -> nothing {
  let err: record = caught {|| conf dir nope --return }
  assert ($err.msg =~ "no directory named 'nope'") $'unknown targets raise: ($err.msg)'
  assert equal $err.code conf::dir::not_found 'the dir code'
  assert ($err.help =~ 'modules') $'the advice lists the directories: ($err.help)'
}

def "test dir list target needs return" []: nothing -> nothing {
  assert equal (conf dir modules --return) (conf machine-config).modules 'a list is returned with --return'
  let err: record = caught {|| conf dir modules }
  assert ($err.msg =~ 'list of directories') $'navigating to a list raises clearly: ($err.msg)'
  assert equal $err.code conf::dir::invalid_argument 'the dir code'
  assert ($err.help =~ '--return') $'the advice names the flag: ($err.help)'
}

# ——— conf auto ————————————————————————————————————————————————————————————————

def "test auto return gives the autoload dir and file paths" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = value $ctx '{dir: (conf auto --return) file: (conf auto foo --return) exists: ($nu.user-autoload-dirs.0 | path exists)}'
    let dir: path = $ctx.config | path join nushell autoload
    assert equal $r.dir $dir 'the user autoload directory'
    assert equal $r.file ($dir | path join foo.nu) 'a target becomes <name>.nu'
    assert $r.exists 'the autoload directory is created'
  }
}

def "test auto vendor return uses the vendor dir" []: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = value $ctx 'conf auto --vendor --return'
    assert equal $dir ($ctx.data | path join nushell vendor autoload) 'the vendor autoload directory'
  }
}

def "test auto raises when the autoload directory cannot be created" []: nothing -> nothing {
  with-sandbox {|ctx|
    # a file where the autoload directory should be: `mkdir` fails
    mkdir ($ctx.config | path join nushell)
    'not a directory' | save ($ctx.config | path join nushell autoload)
    let res: record = child $ctx 'conf auto --return'
    assert ($res.exit_code != 0) 'the failure is an error'
    assert ($res.stderr =~ 'conf::auto::io') $'the io code: ($res.stderr)'
    assert ($res.stderr =~ 'could not create or enter the autoload directory') $'the message names the directory: ($res.stderr)'
  }
}

# ——— conf find ————————————————————————————————————————————————————————————————

# Run `action` with `$env.XDG_CONFIG_DIR` pointing at a populated sandbox config dir.
def with-config [action: closure]: nothing -> any {
  with-sandbox {|ctx|
    let cfg: path = $ctx.code | path join cfg
    mkdir ($cfg | path join one) ($cfg | path join many sub) ($cfg | path join empty)
    'a = 1' | save ($cfg | path join one app.toml)
    'b = 1' | save ($cfg | path join many a.toml)
    'c = 1' | save ($cfg | path join many sub b.toml)
    'x' | save ($cfg | path join top.conf)
    with-env {XDG_CONFIG_DIR: $cfg} { do $action $cfg }
  }
}

def "test find returns a file target" []: nothing -> nothing {
  with-config {|cfg|
    assert equal (conf find top.conf --return) ($cfg | path join top.conf) 'a file under the config dir'
    assert equal (conf find one/app.toml --return) ($cfg | path join one app.toml) 'nested file targets'
  }
}

def "test find resolves a directory with one file" []: nothing -> nothing {
  with-config {|cfg|
    assert equal (conf find one --return) ($cfg | path join one app.toml) 'the only config file'
  }
}

def "test find path joins under the target" []: nothing -> nothing {
  with-config {|cfg|
    assert equal (conf find many --path new.toml --return) ($cfg | path join many new.toml) 'need not exist'
  }
}

def "test find unknown target raises and creates nothing" []: nothing -> nothing {
  with-config {|cfg|
    let err: record = caught {|| conf find typo --return }
    assert ($err.msg =~ 'typo') $'an unknown target raises: ($err.msg)'
    assert equal $err.code conf::find::not_found 'the find error code'
    assert not ($cfg | path join typo | path exists) 'no directory is created for a typo'
  }
}

def "test find empty directory raises" []: nothing -> nothing {
  with-config {|cfg|
    let err: record = caught {|| conf find empty --return }
    assert ($err.msg =~ 'no config files found') $'an empty directory raises: ($err.msg)'
    assert equal $err.code conf::find::not_found 'the find error code'
    assert ($err.help =~ '--path') $'the advice names the flag: ($err.help)'
  }
}

def "test find defaults to the config home" []: nothing -> nothing {
  with-sandbox {|ctx|
    mkdir ($ctx.config | path join sbapp)
    'k = 1' | save ($ctx.config | path join sbapp conf.toml)
    let found: path = value $ctx 'conf find sbapp --return'
    assert equal $found ($ctx.config | path join sbapp conf.toml) 'without XDG_CONFIG_DIR, the parent of the nushell config dir'
  }
}

# ——— conf prompt ——————————————————————————————————————————————————————————————

# A stub `oh-my-posh` that writes the vendor autoload script (tagged with its arguments) like the real one.
# Returns code that puts it first on PATH; it must run after `use conf`, which moves the scope's directories
# (e.g. /usr/bin, where a real oh-my-posh may live) to the front.
def posh-stub [ctx: record]: nothing -> string {
  let bin: path = $ctx.code | path join bin
  mkdir $bin
  let vendor: path = $ctx.data | path join nushell vendor autoload
  [
    '#!/bin/sh'
    $'mkdir -p "($vendor)"'
    $'echo "# generated: $*" > "($vendor)/oh-my-posh.nu"'
  ] | str join (char newline) | save ($bin | path join oh-my-posh)
  ^chmod +x ($bin | path join oh-my-posh)
  $"$env.PATH = \($env.PATH | prepend '($bin)'); "
}

def "test prompt moves the generated script to the user autoload dir" []: nothing -> nothing {
  with-sandbox {|ctx|
    let stub: string = posh-stub $ctx
    let user: path = $ctx.config | path join nushell autoload oh-my-posh.nu
    mkdir ($user | path dirname)
    '# stale' | save $user
    value $ctx $'($stub)conf prompt' | ignore
    assert equal (open --raw $user | str trim) '# generated: init nu' 'an existing user script is replaced'
    assert not ($ctx.data | path join nushell vendor autoload oh-my-posh.nu | path exists) 'the vendor copy is moved'
  }
}

def "test prompt passes the config file" []: nothing -> nothing {
  with-sandbox {|ctx|
    let stub: string = posh-stub $ctx
    let theme: path = $ctx.code | path join theme.yaml
    'x: 1' | save $theme
    value $ctx $'($stub)conf prompt --config ($theme)' | ignore
    let user: path = $ctx.config | path join nushell autoload oh-my-posh.nu
    assert equal (open --raw $user | str trim) $'# generated: init nu --config=($theme)' 'the config is passed on'
  }
}

def "test prompt rejects a missing or unknown config" []: nothing -> nothing {
  with-sandbox {|ctx|
    let stub: string = posh-stub $ctx
    let missing: record = child $ctx $'($stub)conf prompt --config /sbconf/none.yaml'
    assert ($missing.stderr =~ 'file not found') $'a missing config raises: ($missing.stderr)'
    assert ($missing.stderr =~ 'conf::prompt::not_found') $'the not_found code: ($missing.stderr)'
    let txt: path = $ctx.code | path join theme.txt
    'x' | save $txt
    let unknown: record = child $ctx $'($stub)conf prompt --config ($txt)'
    assert ($unknown.stderr =~ 'unexpected configuration file format') $'an unknown format raises: ($unknown.stderr)'
    assert ($unknown.stderr =~ 'conf::prompt::invalid_argument') $'the invalid_argument code: ($unknown.stderr)'
  }
}
