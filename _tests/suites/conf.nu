# `conf` and `conf/machine.nu`: `test _tests/suites/conf.nu`.
#
# `machine-config`'s defaults are parse-time constants derived from `$nu.*`, so they follow the test child's
# sandboxed HOME/XDG directories. Anything that writes files (a fake `~/.profile`, autoload directories, the
# prompt script) runs in a `sandboxed` grandchild whose HOME and XDG directories point into a `with-sandbox`
# tree, so the real home is never touched even with `--no-sandbox`. The ZR-XPS14 host branch is exercised by
# overriding `--host`; it sources `~/.profile` through the vendored `bash-env` (needs `bash` and `jq`).
# nu-lint-ignore-file: missing_output_type
# (helpers return whatever the child or the closure produced)
use conf
use ../mod.nu *

const USER_KEYS: list<string> = [home share cache config state autoload modules binaries scripts]
const VENDOR_KEYS: list<string> = [autoload plugins modules binaries scripts]

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

def need-bash-env []: nothing -> nothing {
  for bin in [bash jq] { if (which $bin | is-empty) { skip $'`($bin)` is needed by bash-env' } }
}

# Write a fake `~/.profile` into the sandbox home.
def profile [ctx: record ...lines: string]: nothing -> nothing {
  $lines | str join (char newline) | save --force ($ctx.home | path join .profile)
}

# ——— machine-config ———————————————————————————————————————————————————————————

def "test machine config rejects an unknown mode" []: nothing -> nothing {
  assert error {|| conf machine-config bogus --host other } 'only user and vendor are modes'
}

def "test machine config rejects an unknown strategy" []: nothing -> nothing {
  assert error {|| conf machine-config --host other --strategy sideways } 'only overwrite/prepend/append'
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

def "test machine config windows branch maps appdata" []: nothing -> nothing {
  let mc: record = conf machine-config --host ZR-XPS14 --os windows --with {APPDATA: /ad LOCALAPPDATA: /lad}
  assert equal [$mc.share $mc.config $mc.state $mc.cache] [/ad /ad /lad /lad] 'APPDATA and LOCALAPPDATA'
  assert equal ($mc | columns) $USER_KEYS 'no extra keys'
}

def "test machine config vendor branch uses NUPM_HOME" []: nothing -> nothing {
  let mc: record = conf machine-config vendor --host ZR-XPS14 --os linux --with {NUPM_HOME: /nupm}
  assert equal [$mc.modules $mc.scripts $mc.binaries] [/nupm/modules /nupm/scripts /usr/bin] 'NUPM_HOME layout'
}

def "test machine config vendor branch defaults NUPM_HOME" []: nothing -> nothing {
  let mc: record = conf machine-config vendor --host ZR-XPS14 --os linux
  let nupm: path = $nu.data-dir | path dirname | path join nupm
  assert equal $mc.modules ($nupm | path join modules) 'nupm next to the nushell data dir'
}

def "test machine config failing branch warns and falls back" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = child $ctx 'conf machine-config --host ZR-XPS14 --os windows'
    assert equal $res.exit_code 0 'a failing branch does not raise'
    assert ($res.stderr =~ 'configuration failed') $'the cause is reported on stderr: ($res.stderr)'
    assert ($res.stderr =~ 'APPDATA') 'the warning names the cause'
    let defaults: record = value $ctx 'conf machine-config --host other'
    assert equal $res.value $defaults 'the defaults are returned'
  }
}

def "test machine config verbose prints the target and is kept by with" []: nothing -> nothing {
  with-sandbox {|ctx|
    let res: record = child $ctx 'conf machine-config --host other --verbose --with {X: 1}'
    assert ($res.stdout =~ 'host = other') $'the target is printed: ($res.stdout)'
  }
}

def "test machine config host branch reads the profile" []: nothing -> nothing {
  need-bash-env
  with-sandbox {|ctx|
    profile $ctx 'export XDG_DATA_DIR="$HOME/d"' 'export XDG_CONFIG_DIR="$HOME/c"' 'export XDG_DOWNLOAD_DIR="$HOME/dl"' 'export PATH="/sbconf/profile/bin:$PATH"'
    let mc: record = value $ctx 'conf machine-config --host ZR-XPS14 --os linux' --vars {WORK: /sbwork}
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

def "test machine config host branch takes only the PATH entries of the profile" []: nothing -> nothing {
  need-bash-env
  with-sandbox {|ctx|
    profile $ctx 'export PATH="/a:$PATH"'
    let path: list<string> = $env.PATH | prepend /sbconf/inherited
    let mc: record = value $ctx 'conf machine-config --host ZR-XPS14 --os linux' --vars {WORK: /sbwork PATH: $path}
    assert ('/a' in $mc.binaries) 'the entry the profile adds'
    assert ('/sbconf/inherited' not-in $mc.binaries) 'not the PATH the shell inherited'
  }
}

def "test machine config host branch takes WORK from the profile" []: nothing -> nothing {
  need-bash-env
  with-sandbox {|ctx|
    profile $ctx 'export WORK=/sbprofile-work'
    let mc: record = value $ctx 'conf machine-config --host ZR-XPS14 --os linux'
    assert equal ($mc.modules | last) /sbprofile-work/ext 'WORK set by the profile is used'
  }
}

def "test machine config host branch without a profile falls back" []: nothing -> nothing {
  need-bash-env
  with-sandbox {|ctx|
    let res: record = child $ctx 'conf machine-config --host ZR-XPS14 --os linux' --vars {WORK: /sbwork}
    assert ($res.stderr =~ '\.profile') $'the missing profile is reported: ($res.stderr)'
    assert equal $res.value (value $ctx 'conf machine-config --host other') 'the defaults are returned'
  }
}

def "test machine config strategy combines lists" []: nothing -> nothing {
  need-bash-env
  with-sandbox {|ctx|
    profile $ctx 'export WORK=/sbwork'
    let defaults: list = value $ctx 'conf machine-config --host other | get modules'
    let prepend: list = value $ctx 'conf machine-config --host ZR-XPS14 --os linux --strategy prepend | get modules'
    let append: list = value $ctx 'conf machine-config --host ZR-XPS14 --os linux --strategy append | get modules'
    let over: list = value $ctx 'conf machine-config --host ZR-XPS14 --os linux | get modules'
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
  let err: record = try { conf dir nope --return; {} } catch {|e| $e }
  assert ($err.msg =~ "no directory named 'nope'") $'unknown targets raise: ($err.msg?)'
}

def "test dir list target needs return" []: nothing -> nothing {
  assert equal (conf dir modules --return) (conf machine-config).modules 'a list is returned with --return'
  let err: record = try { conf dir modules; {} } catch {|e| $e }
  assert ($err.msg =~ 'list of directories') $'navigating to a list raises clearly: ($err.msg?)'
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
    let err: record = try { conf find typo --return; {} } catch {|e| $e }
    assert ($err.msg =~ 'typo') $'an unknown target raises: ($err.msg?)'
    assert equal $err.details?.code? config::find::unresolved_target 'the find error code'
    assert not ($cfg | path join typo | path exists) 'no directory is created for a typo'
  }
}

def "test find empty directory raises" []: nothing -> nothing {
  with-config {|cfg|
    let err: record = try { conf find empty --return; {} } catch {|e| $e }
    assert ($err.msg =~ 'no config files found') $'an empty directory raises: ($err.msg?)'
    assert equal $err.details?.code? config::find::unresolved_target 'the find error code'
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
    let txt: path = $ctx.code | path join theme.txt
    'x' | save $txt
    let unknown: record = child $ctx $'($stub)conf prompt --config ($txt)'
    assert ($unknown.stderr =~ 'unexpected configuration file format') $'an unknown format raises: ($unknown.stderr)'
  }
}
