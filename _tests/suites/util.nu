# `util contains`, `util timestamp` and `util workspace`: `test _tests/suites/util.nu`.
#
# `workspace bump` runs against files in a `with-sandbox` directory; `tombi` and `dprint` are stubbed on PATH.
use util
use ../mod.nu *

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

# Semver values cannot be compared with null or serialized; their text can.
# nu-lint-ignore: missing_in_type, missing_output_type
def text []: any -> any { if ($in | describe) == semver { into string } else { } }

# A bump result with printable versions.
def printable []: table -> table { update prev { text } | update curr { text } }

# ——— contains —————————————————————————————————————————————————————————————————

def "test contains examples" []: nothing -> nothing {
  assert equal ({a: {b: 1}} | util contains $.a.b) true 'a present key'
  assert equal ([1 2] | util contains $.5) false 'a missing index'
}

def "test contains on records" []: nothing -> nothing {
  assert equal ({a: 1} | util contains $.a) true 'a top-level key'
  assert equal ({a: 1} | util contains $.b) false 'a missing key'
  assert equal ({a: {b: 1}} | util contains $.a.c) false 'a missing nested key'
  assert equal ({a: null} | util contains $.a) true 'a present null is a value'
}

def "test contains on lists and tables" []: nothing -> nothing {
  assert equal ([1 2] | util contains $.1) true 'an index in range'
  assert equal ([] | util contains $.0) false 'an empty list has no index'
  assert equal ([{a: 1} {a: 2}] | util contains $.a) true 'a table column'
  assert equal ([{a: 1} {a: 2}] | util contains $.1.a) true 'a cell'
  assert equal ([{a: 1}] | util contains $.b) false 'a missing column'
}

def "test contains optional suffix is always true" []: nothing -> nothing {
  assert equal ({a: 1} | util contains $.b?) true 'an optional member never fails'
  assert equal ([] | util contains $.0?) true 'also for lists'
}

def "test contains insensitive suffix" []: nothing -> nothing {
  assert equal ({A: 1} | util contains $.a!) true 'the case is ignored'
  assert equal ({A: 1} | util contains $.a) false 'the case matters without it'
}

# ——— timestamp ————————————————————————————————————————————————————————————————

def "test timestamp examples" []: nothing -> nothing {
  assert equal (2020-01-02T03:04:05Z | util timestamp) '2020-01-02T03:04:05+00:00' 'a datetime'
  assert equal ('2020-01-02T03:04:05+02:00' | util timestamp) '2020-01-02T03:04:05+02:00' 'an ISO string'
}

def "test timestamp formats a datetime as rfc 3339" []: nothing -> nothing {
  assert equal (2020-01-02T03:04:05.5-06:00 | util timestamp) '2020-01-02T03:04:05.500-06:00' 'fractions and offsets are kept'
}

def "test timestamp keeps the time and offset of iso strings" []: nothing -> nothing {
  assert equal ('2020-01-02T03:04:05Z' | util timestamp) '2020-01-02T03:04:05+00:00' 'a UTC string'
  assert equal ('2020-01-02 03:04:05 +05:30' | util timestamp) '2020-01-02T03:04:05+05:30' 'a spaced string with an offset'
}

def "test timestamp parses a bare date as local midnight" []: nothing -> nothing {
  assert str contains ('2020-01-02' | util timestamp) '2020-01-02T00:00:00' 'midnight, not the current time'
}

def "test timestamp falls back to human dates" []: nothing -> nothing {
  let expected = (date now) + 2hr
  let parsed = 'in 2 hours' | util timestamp | into datetime
  assert ((($parsed - $expected) | math abs) < 1min) 'a relative phrase is parsed by date from-human'
  let yesterday = 'yesterday' | util timestamp | into datetime
  assert ((((date now) - 1day) - $yesterday | math abs) < 1min) 'yesterday'
}

def "test timestamp defaults to now" []: nothing -> nothing {
  let stamp = null | util timestamp
  assert ($stamp =~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d') 'an RFC 3339 string'
  assert (((date now) - ($stamp | into datetime) | math abs) < 1min) 'the current time'
}

def "test timestamp rejects unparseable strings" []: nothing -> nothing {
  assert error { 'not a date at all' | util timestamp } 'neither parser accepts it'
}

# ——— workspace ————————————————————————————————————————————————————————————————

def "test util re-exports workspace" []: nothing -> nothing {
  assert ('util workspace bump' in (scope commands | get name)) 'bump is reachable as util workspace bump'
  assert ('util workspace reactivate' in (scope aliases | get name)) 'the aliases too'
  assert equal $util.workspace.LEVEL [major minor patch alpha beta rc release] 'the LEVEL constant'
}

# Files to bump: a yaml and a nuon version file, in `dir`.
def seed [dir: path]: nothing -> table<file: path, cell: cell-path> {
  'name: x
version: 1.2.3
' | save ($dir | path join app.yaml)
  {meta: {v: '2.0.0+build.7'}} | to nuon | save ($dir | path join pkg.nuon)
  [[file cell]; [($dir | path join app.yaml) $.version] [($dir | path join pkg.nuon) $.meta.v]]
}

def "test bump of two cells in the same file keeps both updates" []: nothing -> nothing {
  with-sandbox {|ctx|
    let f: path = $ctx.code | path join two.nuon
    {a: {v: '1.0.0'} b: {v: '2.0.0'}} | to nuon | save --force $f
    [[file cell]; [$f $.a.v] [$f $.b.v]] | util workspace bump | ignore
    assert equal (open $f) {a: {v: '1.0.1'} b: {v: '2.0.1'}} 'sequential writes: neither bump is lost'
  }
}

def "test bump writes the next patch version" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code
    let out = $files | util workspace bump | printable
    assert equal ($out | select prev curr) [[prev curr]; ['1.2.3' '1.2.4'] ['2.0.0+build.7' '2.0.1+build.7']] 'the build metadata is kept'
    assert equal ($out | get file) ($files | get file) 'every row names its file'
    assert equal (open ($files.0?.file?) | get version) '1.2.4' 'yaml is written'
    assert equal (open ($files.0?.file?) | get name) x 'other keys are kept'
    assert equal (open ($files.1?.file?) | get meta.v) '2.0.1+build.7' 'nuon is written at the nested cell'
  }
}

def "test bump levels" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code | first 1
    let bumped = {|level| $files | util workspace bump --test $level | get curr.0 | text }
    assert equal (do $bumped major) '2.0.0' 'major'
    assert equal (do $bumped minor) '1.3.0' 'minor'
    assert equal (do $bumped patch) '1.2.4' 'patch'
    # pre-release numbering is `semver bump`'s own; only the label is the module's concern
    for level in [alpha beta rc] {
      assert ((do $bumped $level) =~ $'-($level)\.1$') $'($level) starts a pre-release'
    }
  }
}

def "test bump test mode writes nothing" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code
    let before = $files | each { open --raw $in.file }
    let out = $files | util workspace bump --test | printable
    assert equal ($out | get curr) ['1.2.4' '2.0.1+build.7'] 'the next versions are returned'
    assert equal ($files | each { open --raw $in.file }) $before 'the files are unchanged'
  }
}

def "test bump meta replaces the build metadata" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code
    let out = $files | util workspace bump --test --meta 'ci.9' | printable
    assert equal ($out | get curr) ['1.2.4+ci.9' '2.0.1+ci.9'] 'the given metadata wins'
  }
}

def "test bump meta replaces the build metadata of a spec" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code | first 1
    assert equal ($files | util workspace bump --test --spec '3.1.4+old' --meta 'ci.9' | get curr.0 | text) '3.1.4+ci.9' "the spec's own metadata is replaced"
    assert equal ($files | util workspace bump --test --spec '3.1.4' --meta 'ci.9' | get curr.0 | text) '3.1.4+ci.9' 'or added'
    assert error { $files | util workspace bump --test --spec '3.1.4' --meta 'not valid!' } 'the result is still validated as semver'
  }
}

def "test bump spec sets an exact version" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code | first 1
    let out = $files | util workspace bump --spec '3.1.4-rc.2'
    assert equal ($out.0?.curr? | describe) semver 'the spec is a semver value like other results'
    assert equal ($out.0?.curr? | text) '3.1.4-rc.2' 'the spec is the new version'
    assert equal (open ($files.0?.file?) | get version) '3.1.4-rc.2' 'and is written'
  }
}

def "test bump rejects an invalid spec" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code | first 1
    assert error { $files | util workspace bump --spec banana } 'not semver'
    assert equal (open ($files.0?.file?) | get version) '1.2.3' 'nothing is written'
  }
}

def "test bump leaves an unchanged version alone" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code | first 1
    let before = open --raw $files.0?.file?
    let out = $files | util workspace bump --spec 1.2.3 | printable
    assert equal ($out | select prev curr) [[prev curr]; ['1.2.3' '1.2.3']] 'the same version'
    assert equal (open --raw $files.0?.file?) $before 'the file is not re-serialized'
  }
}

def "test bump skips missing and unsupported files" []: nothing -> nothing {
  with-sandbox {|ctx|
    'version = 1' | save ($ctx.code | path join notes.ini)
    let rows = [[file cell]; [($ctx.code | path join gone.yaml) $.version] [($ctx.code | path join notes.ini) $.version]]
    let out = $rows | util workspace bump
    assert equal ($out | select prev curr) [[prev curr]; [null null] [null null]] 'null versions'
    assert equal ($out | get file) ($rows | get file) 'the rows are returned'
  }
}

def "test bump raises for missing files without skip" []: nothing -> nothing {
  with-sandbox {|ctx|
    let gone = $ctx.code | path join gone.yaml
    let e = caught { [[file cell]; [$gone $.version]] | util workspace bump --skip=false }
    assert equal $e.msg $"file not found: '($gone)'" 'the message names the file'
    assert equal $e.code 'util::workspace::ensure-bumpable::not_found' 'the derived code names the submodule and the helper that checks'
    'version = 1' | save ($ctx.code | path join notes.ini)
    let e = caught { [[file cell]; [($ctx.code | path join notes.ini) $.version]] | util workspace bump --skip=false }
    assert equal $e.msg "unsupported file extension: 'ini'" 'the extension is named'
    assert equal $e.code 'util::workspace::ensure-bumpable::unsupported' 'an unsupported format'
    assert str contains $e.help 'toml' 'the advice lists the formats'
  }
}

def "test bump raises for an invalid cell path" []: nothing -> nothing {
  with-sandbox {|ctx|
    let files = seed $ctx.code | first 1 | update cell $.nope
    let e = caught { $files | util workspace bump --test }
    assert equal $e.msg $"no version at '$.nope' in '($files.0?.file?)'" 'the path and the file are named'
    assert equal $e.code 'util::workspace::bump::not_found' 'the derived code'
    assert equal ($e.inner | length) 1 'the cause (the failed `get`) is the inner error'
  }
}

# Executable stubs for the formatters, appending their arguments to `log`.
def stub-formatters [ctx: record]: nothing -> path {
  need-posix
  let bin = $ctx.code | path join bin
  mkdir $bin
  for name in [tombi dprint] {
    $"#!/bin/sh\necho \"($name) $*\" >> \"$STUB_LOG\"\n" | save ($bin | path join $name)
    chmod +x ($bin | path join $name)
  }
  $bin
}

def "test bump formats toml and json files" []: nothing -> nothing {
  if (which sh | is-empty) { skip 'sh is not installed' }
  with-sandbox {|ctx|
    let bin = stub-formatters $ctx
    let log = $ctx.code | path join formatters.log
    let toml = $ctx.code | path join Cargo.toml
    let json = $ctx.code | path join package.json
    {package: {version: '0.1.0'}} | to toml | save $toml
    {version: '0.1.0'} | to json | save $json
    with-env {PATH: [$bin ...$env.PATH] STUB_LOG: $log} {
      [[file cell]; [$toml $.package.version] [$json $.version]] | util workspace bump | ignore
    }
    assert equal (open $toml | get package.version) '0.1.1' 'toml is written'
    assert equal (open $json | get version) '0.1.1' 'json is written'
    assert equal (open $log | lines | sort) [$"dprint fmt ($json)" $"tombi format ($toml)"] 'each formatter runs on its file'
  }
}

def "test bump ignores formatter failures" []: nothing -> nothing {
  need-posix
  with-sandbox {|ctx|
    let bin = $ctx.code | path join bin
    mkdir $bin
    "#!/bin/sh\nexit 3\n" | save ($bin | path join tombi)
    chmod +x ($bin | path join tombi)
    let toml = $ctx.code | path join Cargo.toml
    {package: {version: '0.1.0'}} | to toml | save $toml
    let out = with-env {PATH: [$bin ...$env.PATH]} { [[file cell]; [$toml $.package.version]] | util workspace bump }
    assert equal ($out.0?.curr? | text) '0.1.1' 'the bump succeeds'
  }
}

def "test bump keeps the input order" []: nothing -> nothing {
  with-sandbox {|ctx|
    let rows = 1..8 | each {|i|
      let file = $ctx.code | path join $'v($i).nuon'
      {v: $'($i).0.0'} | to nuon | save $file
      {file: $file cell: $.v}
    }
    assert equal ($rows | util workspace bump --test | get prev | each { text }) (1..8 | each { $'($in).0.0' }) 'input order'
  }
}

def "test deactivate needs the workspace overlay" []: nothing -> nothing {
  with-sandbox {|ctx|
    let missing = sandboxed $ctx 'util workspace deactivate' --prelude 'use util'
    assert ($missing.exit_code != 0) 'an error without the overlay'
    let hidden = sandboxed $ctx 'overlay new __workspace__
use util
util workspace deactivate
overlay list | where active | get name | to nuon' --pipe
    assert ('__workspace__' not-in $hidden) 'the overlay is hidden'
  }
}

# Nushell runs `env_change.PWD` hooks before the next prompt, from the net change of PWD, so a hook registered here
# cannot observe the alias (and never runs in a test child); what it leaves behind can.
def "test reactivate leaves and returns to the current directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    cd $ctx.code
    $env.OLDPWD = $ctx.code
    util workspace reactivate
    assert equal $env.PWD $ctx.code 'the directory is unchanged'
    assert equal ($env.OLDPWD | path expand) ($nu.temp-dir | path expand) 'it did leave: the temporary directory is the previous one'
  }
}
