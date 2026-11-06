# `mods` (abstract) and `mods/local` (`edit`, resolved through the machine configuration):
# `test _tests/suites/mods.nu`.
#
# The registry lives in in-memory `std-rfc/kv` tables, so it is fresh in every test child. `use mods` sets
# `mods_home` to the first existing NU_LIB_DIRS entry, which is the repository root in test children: every
# test that defines a module passes `--directory` or points `mods_home` at a sandbox, so nothing is written
# into the repository. Cases that depend on the environment `use mods` starts from run in sandboxed children,
# which first hide the `mods_home` this suite's own `use mods` set (the runner's scrubbing cannot hide variables
# set by a suite's imports).
# nu-lint-ignore-file: missing_output_type
# (helpers return whatever the child produced)
use mods
use ../mod.nu *

const HOOK: string = 'mods::use_or_hide::update-mods-used'

# Run `code` (serialized as nuon) after `prelude` in a sandboxed child; fail with its stderr on error.
def value [ctx: record code: string --vars: record = {} --prelude: string = 'use mods']: nothing -> any {
  let res: record = sandboxed $ctx $"($code) | to nuon --serialize" --prelude $prelude --vars $vars
  if $res.exit_code != 0 { error make --unspanned {msg: $"child failed: ($res.stderr | str trim)"} }
  $res.stdout | lines | last | from nuon
}

def module-id [name: string]: nothing -> int {
  scope modules | where name == $name | get 0.module_id
}

# ——— refresh ——————————————————————————————————————————————————————————————————

def "test refresh registers a used module" []: nothing -> nothing {
  assert equal (mods refresh 'use mods' --return all) [[name module_id]; [mods (module-id mods)]] 'name and id'
}

def "test refresh hide moves a module to the hidden registry" []: nothing -> nothing {
  mods refresh 'use mods'
  mods refresh 'hide mods'
  assert equal (mods refresh --return names) [] 'no longer used'
  assert equal (mods list --hidden --short) [mods] 'now hidden'
}

def "test refresh overlay use unhides a module" []: nothing -> nothing {
  mods refresh 'hide mods'
  assert equal (mods refresh 'overlay use mods' --return names) [mods] 'overlay use registers it again'
  assert equal (mods list --hidden --short) [] 'and drops it from the hidden registry'
}

def "test refresh uses the last path segment as the module name" []: nothing -> nothing {
  assert equal (mods refresh 'use std/assert' --return names) [assert] 'use std/assert registers assert'
}

def "test refresh handles every statement of a line" []: nothing -> nothing {
  let names: list<string> = mods refresh 'use mods; use std/assert' --return names
  assert equal ($names | sort) [assert mods] 'both statements are registered'
}

def "test refresh ignores unknown modules" []: nothing -> nothing {
  assert equal (mods refresh 'use sbmods_missing' --return names) [] 'modules that are not loaded are not stored'
}

def "test refresh returns ids" []: nothing -> nothing {
  assert equal (mods refresh 'use mods' --return module_ids) [(module-id mods)] 'module ids'
}

def "test refresh without return returns nothing" []: nothing -> nothing {
  assert equal (mods refresh 'use mods') null 'no --return, no output'
}

def "test refresh registers piped scope rows" []: nothing -> nothing {
  let names: list<string> = scope modules | where name == mods | mods refresh --return names
  assert equal $names [mods] 'piped rows are registered'
}

def "test refresh drops piped rows that are hidden" []: nothing -> nothing {
  mods refresh 'hide mods'
  let names: list<string> = scope modules | where name == mods | mods refresh --return names
  assert equal $names [] 'a hidden module stays unregistered'
}

# ——— list —————————————————————————————————————————————————————————————————————

def "test list short names the loaded modules" []: nothing -> nothing {
  let names: list<string> = mods list --short
  assert ('mods' in $names) 'mods is loaded'
  assert ($names | all { $in !~ '^_' }) 'private modules are omitted'
}

def "test list describes a module" []: nothing -> nothing {
  let row: record = mods list mods
  assert equal ($row | columns) [name description location] 'the information columns'
  assert ($row.description starts-with 'Utilities for interacting with Nushell modules') 'the module description'
  assert not ($row.description ends-with (char newline)) 'without a trailing newline'
}

def "test list commands flattens the exports" []: nothing -> nothing {
  let row: record = mods list mods --commands
  assert ($row has commands) 'the exported commands are included'
}

def "test list absolute keeps the full location" []: nothing -> nothing {
  assert equal (mods list mods --absolute).location ($ROOT | path join mods) 'the module directory'
}

def "test list update registers the listed modules" []: nothing -> nothing {
  mods list --update --short | ignore
  assert ('mods' in (mods refresh --return names)) 'listing with --update registers the modules'
}

def "test list location uses the mods home shorthand" []: nothing -> nothing {
  with-sandbox {|ctx|
    let loc: string = value $ctx '(mods list mods).location' --vars {mods_home: $ROOT}
    assert equal $loc '@/mods' 'mods_home becomes @'
  }
}

def "test list location without mods home or nupm home" []: nothing -> nothing {
  with-sandbox {|ctx|
    # NU_LIB_DIRS without an existing entry: mods_home stays unset.
    let prelude: string = 'hide-env --ignore-errors mods_home; $env.NU_LIB_DIRS = []; use mods'
    let r: record = value $ctx '{home: $env.mods_home? loc: (mods list mods).location}' --prelude $prelude
    assert equal $r.home null 'no mods_home is derived'
    assert equal $r.loc ($ROOT | path join mods) 'an unset prefix never rewrites a location'
  }
}

def "test shorthand rows follow the set prefixes" []: nothing -> nothing {
  with-sandbox {|ctx|
    let with_nupm: table = value $ctx '$env.mods_refs' --vars {NUPM_HOME: /sbnupm mods_home: /sbhome}
    assert equal $with_nupm [[find replace]; [/sbnupm/modules '$'] [/sbhome '@'] [$ctx.home '~']] 'nupm modules, mods_home, then home'
    let without: table = value $ctx '$env.mods_refs' --vars {mods_home: /sbhome}
    assert equal $without.replace ['@' '~'] 'an unset NUPM_HOME adds no row'
  }
}

# ——— define ———————————————————————————————————————————————————————————————————

def "test define writes the closure body as a module" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = mods define sbmod {||
      export def hello [] { 'hi' }
    } --directory $ctx.code
    assert equal $file ($ctx.code | path join sbmod mod.nu) 'saved as <dir>/<name>/mod.nu'
    assert equal (open --raw $file | lines) ["export def hello [] { 'hi' }" ''] 'the body without braces, left-trimmed, then a blank line'
    let res: record = sandboxed $ctx 'sbmod hello' --prelude $'use ($file | path dirname)'
    assert equal ($res.stdout | str trim) 'hi' 'the saved module works'
  }
}

def "test define refuses to overwrite" []: nothing -> nothing {
  with-sandbox {|ctx|
    mods define sbmod {|| export def a [] { 1 } } --directory $ctx.code | ignore
    assert error {|| mods define sbmod {|| export def b [] { 2 } } --directory $ctx.code } 'an existing module is kept'
    mods define sbmod {|| export def b [] { 2 } } --directory $ctx.code --overwrite | ignore
    assert ((open --raw ($ctx.code | path join sbmod mod.nu)) =~ 'def b') '--overwrite replaces it'
  }
}

def "test define defaults to mods home" []: nothing -> nothing {
  with-sandbox {|ctx|
    $env.mods_home = $ctx.code
    assert equal (mods define sbhome {|| }) ($ctx.code | path join sbhome mod.nu) 'saved under $env.mods_home'
  }
}

def "test define without a directory or mods home raises" []: nothing -> nothing {
  $env.mods_home = null
  # Guard: with mods_home still set, define would write into it (the repository root in test children).
  if $env.mods_home != null { error make --unspanned {msg: 'could not unset mods_home'} }
  let err: record = try { mods define sbnone {|| }; {} } catch {|e| $e }
  assert ($err.msg =~ 'mods_home') $'the error says how to fix it: ($err.msg?)'
}

# ——— mods (main) ——————————————————————————————————————————————————————————————

def "test main returns the tracked modules" []: nothing -> nothing {
  let tracked: table = mods
  assert equal ($tracked | columns) [name module_id] 'a name/module_id table'
  assert ('mods' in $tracked.name) 'loaded modules are registered by every call'
}

def "test main with a name returns it when loaded" []: nothing -> nothing {
  assert equal (mods mods) 'mods' 'the module name'
}

def "test main all lists the module names" []: nothing -> nothing {
  assert ('mods' in (mods --all)) 'names including overlays'
}

def "test main defines a closure with a name" []: nothing -> nothing {
  with-sandbox {|ctx|
    $env.mods_home = $ctx.code
    let file: path = {|| export def x [] { 1 } } | mods sbclosure
    assert equal $file ($ctx.code | path join sbclosure mod.nu) 'defined under mods_home'
  }
}

def "test main closure without a name raises" []: nothing -> nothing {
  assert error {|| {|| } | mods } 'a name is required'
}

def "test main defines a details record" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = {name: sbrec definition: {|| export def y [] { 2 } } directory: $ctx.code} | mods
    assert equal $file ($ctx.code | path join sbrec mod.nu) 'the record directory is used'
    let again: path = {name: sbrec definition: {|| export def z [] { 3 } } directory: $ctx.code overwrite: true} | mods
    assert ((open --raw $again) =~ 'def z') 'overwrite in the record is honoured'
  }
}

def "test main details record takes the name argument" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = {definition: {|| } directory: $ctx.code} | mods sbnamed
    assert equal $file ($ctx.code | path join sbnamed mod.nu) 'the positional name fills in'
  }
}

def "test main defines a mapping of modules" []: nothing -> nothing {
  with-sandbox {|ctx|
    $env.mods_home = $ctx.code
    let files: list<path> = {sbone: {|| export def a [] { 1 } } sbtwo: {|| export def b [] { 2 } }} | mods
    assert equal $files [($ctx.code | path join sbone mod.nu) ($ctx.code | path join sbtwo mod.nu)] 'one file per entry, in order'
  }
}

def "test main details record without a definition raises" []: nothing -> nothing {
  assert error {|| {name: sbx definition: null directory: /tmp} | mods } 'a definition is required'
}

# ——— export-env ———————————————————————————————————————————————————————————————

def "test use mods derives mods home from the lib dirs" []: nothing -> nothing {
  with-sandbox {|ctx|
    let prelude: string = $"hide-env --ignore-errors mods_home; $env.NU_LIB_DIRS = ['/sbmods/missing' '($ctx.code)']; use mods"
    assert equal (value $ctx '$env.mods_home' --prelude $prelude) $ctx.code 'the first existing entry'
  }
}

def "test use mods keeps a preset mods home" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r: record = value $ctx '{home: $env.mods_home refs: $env.mods_refs}' --vars {mods_home: /sbmods/preset}
    assert equal $r.home /sbmods/preset 'mods_home is not overwritten'
    assert ({find: /sbmods/preset replace: '@'} in $r.refs) 'the shorthand follows the preset home'
  }
}

def "test use mods registers the hook once" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list = value $ctx '$env.config.hooks.pre_execution | get name' --prelude 'use mods; use mods'
    assert equal $names [$HOOK] 'the tracking hook is added once'
  }
}

# ——— mods/local ———————————————————————————————————————————————————————————————

def "test local exposes the abstract commands and edit" []: nothing -> nothing {
  with-sandbox {|ctx|
    let names: list<string> = value $ctx "scope commands | where name =~ '^local( |$)' | get name | sort" --prelude 'use mods/local'
    assert equal $names ['local define' 'local edit' 'local list' 'local refresh'] 'no stray re-exported main'
  }
}

# Run `mods/local` code in a sandbox whose user module and script dirs hold a few definitions.
def in-local [code: string --vars: record = {}]: nothing -> any {
  with-sandbox {|ctx|
    let modules: path = $ctx.config | path join nushell modules
    let scripts: path = $ctx.config | path join nushell scripts
    for f in [sbalpha/mod.nu sbalpha/extra.nu sbbeta/mod.nu sbbeta/sbalpha.nu sbbeta/deep/sbgamma.nu] {
      mkdir ($modules | path join $f | path dirname)
      touch ($modules | path join $f)
    }
    mkdir $scripts
    touch ($scripts | path join sbscript.nu)
    do {|| value $ctx $code --prelude 'use mods/local' --vars $vars } | {ctx: $ctx modules: $modules scripts: $scripts value: $in}
  }
}

def "test local edit matches the module name first" []: nothing -> nothing {
  let r: record = in-local 'local edit sbalpha --get'
  assert equal $r.value ($r.modules | path join sbalpha mod.nu) 'sbalpha/mod.nu beats sbbeta/sbalpha.nu'
}

def "test local edit matches a library module by name" []: nothing -> nothing {
  let r: record = in-local 'local edit conf --get'
  assert equal $r.value ($ROOT | path join conf mod.nu) 'conf resolves to conf/mod.nu, not conf/machine.nu'
}

def "test local edit matches a relative path" []: nothing -> nothing {
  let r: record = in-local '[(local edit conf/machine --get) (local edit machine.nu --get) (local edit sbbeta/sbalpha --get)]'
  assert equal $r.value [($ROOT | path join conf machine.nu) ($ROOT | path join conf machine.nu) ($r.modules | path join sbbeta sbalpha.nu)] 'whole or trailing relative paths'
}

def "test local edit finds scripts" []: nothing -> nothing {
  let r: record = in-local 'local edit sbscript --get'
  assert equal $r.value ($r.scripts | path join sbscript.nu) 'script directories are searched too'
}

def "test local edit falls back to a substring" []: nothing -> nothing {
  let r: record = in-local 'local edit sbgam --get'
  assert equal $r.value ($r.modules | path join sbbeta deep sbgamma.nu) 'any part of the relative path'
}

def "test local edit raises when nothing matches" []: nothing -> nothing {
  let r: record = with-sandbox {|ctx| sandboxed $ctx 'local edit sbmods_nothing_here --get' --prelude 'use mods/local' }
  assert ($r.exit_code != 0 and $r.stderr =~ 'no definition found') $'an unknown target raises: ($r.stderr)'
}

def "test local edit opens the editor" []: nothing -> nothing {
  with-sandbox {|ctx|
    let log: path = $ctx.code | path join editor.log
    let stub: path = $ctx.code | path join editor
    $"#!/bin/sh\necho \"$@\" >> '($log)'\n" | save $stub
    ^chmod +x $stub
    sandboxed $ctx 'local edit conf' --prelude 'use mods/local' --vars {EDITOR: $stub} | ignore
    assert equal (open --raw $log | str trim) ($ROOT | path join conf mod.nu) 'the resolved file is passed to $EDITOR'
  }
}
