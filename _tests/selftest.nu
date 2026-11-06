#!/usr/bin/env -S nu --no-config-file
# Self-test for the `test` runner (test/mod.nu) that does not use the runner to test itself.
#
# Each case builds a throwaway project (suites, project file, fixture modules) in a temp directory, drives the
# runner in a fresh child interpreter with this checkout on the include path, and checks the returned data with
# std/assert. Nothing outside the temp directories is touched.
#
# Usage:
#   nu _tests/selftest.nu            # run every case
#   nu _tests/selftest.nu hooks      # run cases whose name matches a regex

# nu-lint-ignore-file: missing_output_type

# The checkout is the include path for `use style` (a parse-time constant, so it must precede the import).
const NU_LIB_DIRS: list<path> = [(path self ..)]

use std/assert
use style

const ROOT: path = path self ..

# ——— fixtures —————————————————————————————————————————————————————————————————

# Create a temp project from a record of relative path -> file text; returns its directory.
# `main` points TMPDIR at a per-case directory and removes it afterwards, so cases never clean up themselves.
def project [files: record]: nothing -> path {
  let dir: path = mktemp --directory --tmpdir nutest-self-XXXXXX
  for f in ($files | transpose rel text) {
    let p: path = $dir | path join $f.rel
    mkdir ($p | path dirname)
    $f.text | save --force $p
  }
  $dir
}

# Run `code` after `use test` in a fresh interpreter whose PWD is `dir`.
# Returns {value, stdout, stderr, exit_code}; `value` is the code's result (null when the child failed).
# The caller's `NU_TEST` (a global default, e.g. from config.nu) is dropped: a case sees only what `--vars` sets.
def runner [dir: path code: string --vars: record = {}]: nothing -> record {
  let res: record = do {
    cd $dir
    with-env ({NU_TEST: null} | merge $vars) {
      ^$nu.current-exe --no-config-file --include-path=($ROOT) --commands=$"use test\n($code) | to nuon --serialize" | complete
    }
  }
  $res | insert value (if $res.exit_code == 0 { $res.stdout | from nuon })
}

# Like `runner`, but the child must succeed; returns its value.
def ok [dir: path code: string --vars: record = {}]: nothing -> any {
  let res: record = runner $dir $code --vars=$vars
  if $res.exit_code != 0 { error make --unspanned {msg: $"runner child failed: ($res.stderr | str trim)"} }
  $res.value
}

# {test-name: status} for compact assertions.
def statuses []: list -> record {
  each {|row| {$row.name: $row.status} } | into record
}

def row [name: string]: list -> record { where name == $name | first }

# A minimal passing suite.
const PASSING: string = r#'
use std/assert
def "test passes" [] { assert true }
'#

const STATUSES: string = r#'
use std/assert
use test skip
def "test ok" [] { assert true }
def "test fail" [] { assert equal 1 2 "one is not two" }
def "test skipped" [] { skip "no tool here" }
# ignore: not ready yet
def "test ignored" [] { assert false }
def "test a/b: c-d.e" [] { assert true }
'#

# Hooks that log every call to $env.LOG and pass contexts along.
const HOOKED: string = r#'
use std/assert
def log [line: string] { $"($line)\n" | save --append $env.LOG }
def --env "before all" [] { $env.FROM_ALL = 'yes'; log all; {n: 1} }
def "before each" []: record -> record { log each; $in | insert m 2 }
def "after each" []: record -> nothing { log $"after:($in.m)" }
def "after all" []: record -> nothing { log $"done:($in.n)" }
def "test sees contexts" []: record -> nothing { assert equal $in {n: 1 m: 2}; assert equal $env.FROM_ALL yes }
def "test fails" []: record -> nothing { assert false }
'#

const GREET: string = r#'
# Fixture library module.
export def hello [] { 'hi' }
'#

# ——— cases ————————————————————————————————————————————————————————————————————

def cases []: nothing -> list<record<name: string, run: closure>> {[
  {name: 'discover: roles, definition order, ignore markers, imported names excluded' run: {||
    let dir = project {'tests/suites/a.nu': r#'
use std/assert
use std/testing *
use test
def helper [] { 1 }
def "test b" [] { }
# ignore: not ready
def "test c" [] { }
# Ignores leading whitespace (a description that merely starts with the letters is no marker)
def "test d" [] { }
@test
def attr-a [] { }
@ignore
@test
def attr-ignored [] { }
def "before each" [] { }
'#}
    let found = ok $dir 'test discover tests/suites/a.nu'
    assert equal $found [
      [name role ignore];
      ["test b" test false]
      ["test c" test true]
      ["test d" test false]
      [attr-a test false]
      [attr-ignored test true]
      ["before each" before-each false]
    ]
  }}

  {name: 'run: statuses, skip reasons, ignored tests, failure text, punctuation in names' run: {||
    let dir = project {'tests/suites/s.nu': $STATUSES}
    let rows = ok $dir 'test'
    assert equal ($rows | columns) [suite name status duration error file]
    assert equal ($rows | statuses) {
      'test ok': ok 'test fail': fail 'test skipped': skip 'test a/b: c-d.e': ok 'test ignored': skip
    }
    assert str contains ($rows | row 'test fail').error 'one is not two'
    assert equal ($rows | row 'test skipped').error 'no tool here'
    assert equal ($rows | row 'test ignored').error 'ignored'
    assert equal ($rows | get suite | uniq) [s]
    # The declared output type admits passing rows (null error): the result can be bound with a type.
    assert equal (ok $dir 'let r: table = test; $r | length') 5
  }}

  {name: 'run: names that cannot be called are reported, the rest still run' run: {||
    # Quoted names with escapes or doubled quotes are read as the parser reads them: reported, never dropped.
    let dir = project {'tests/suites/n.nu': `def "test it's broken" [] { }
def "test a|b" [] { }
def "test a {b}" [] { }
def "test a;b" [] { }
def "test a]b" [] { }
def "test say \"hi\"" [] { error make {msg: ran} }
def 'test it''s' [] { }
def "test a\\b" [] { }
def "test a --flag" [] { }
def "test a && b" [] { }
def "test a = b" [] { }
def "test a =" [] { }
def "test a=b" [] { }
def "test fine one" [] { }`}
    # A bare `=` or `&&` word is an assignment or the shell operator to the parser; glued to a word it is just text.
    let expected = {
      'test a --flag': ok 'test fine one': ok 'test a\b': ok 'test a=b': ok
      "test it's broken": error 'test a|b': error 'test a {b}': error 'test a;b': error 'test a]b': error
      'test say "hi"': error "test it''s": error 'test a && b': error 'test a = b': error 'test a =': error
    }
    let rows = ok $dir 'test --isolation suite'
    assert equal ($rows | statuses) $expected
    assert equal (ok $dir 'test' | statuses) $expected 'the same under test isolation'
    for name in ["test it's broken" 'test a]b' 'test say "hi"' "test it''s" 'test a && b' 'test a = b'] {
      assert str contains ($rows | row $name).error 'cannot be called' $name
    }
  }}

  {name: 'discover: output printed while the suite loads does not break discovery' run: {||
    let dir = project {'tests/suites/noisy.nu': 'print "hello from top level"
def "test quiet" [] { }'}
    assert equal (ok $dir 'test' | statuses) {'test quiet': ok}
  }}

  {name: 'run: --jobs gives the same results as sequential, and really runs in parallel' run: {||
    let dir = project {'tests/suites/s.nu': $STATUSES 'tests/suites/slow.nu': (1..4 | each {|i| $'def "test s($i)" [] { sleep 1sec }' } | str join "\n")}
    let one = ok $dir 'test tests/suites/s.nu | select name status'
    let many = ok $dir 'test tests/suites/s.nu --jobs 4 | select name status'
    assert equal $many $one
    let start = date now
    ok $dir 'test tests/suites/slow.nu --jobs 4 | get status' | ignore
    let wall = (date now) - $start
    assert ($wall < 3sec) $'four 1-second tests with --jobs 4 took ($wall): not parallel'
  }}

  {name: 'run: output without a trailing newline and marker-like output do not break rows' run: {||
    let dir = project {'tests/suites/o.nu': 'use std/assert
def "test prints without newline" [] { ^printf abc; assert true }
def "test prints a marker-like line" [] { print "#NUTEST-ROW#notbase64!!"; assert true }'}
    assert equal (ok $dir 'test' | statuses) {'test prints without newline': ok 'test prints a marker-like line': ok}
  }}

  {name: 'run: suite isolation survives a suite with hundreds of tests' run: {||
    let dir = project {'tests/suites/big.nu': (1..220 | each {|i| $'def "test number ($i) of many with a reasonably long descriptive name" [] {{ }}' } | str join "\n")}
    let rows = ok $dir 'test --isolation suite'
    assert equal ($rows | length) 220
    assert equal ($rows | where status != ok) []
  }}

  {name: 'run: a redirection token in a test name is reported, not executed' run: {||
    let dir = project {'tests/suites/r.nu': 'def "test o> out" [] { error make {msg: ran} }
def "test fine" [] { }'}
    let rows = ok $dir 'test'
    assert equal ($rows | statuses) {'test o> out': error 'test fine': ok}
    assert str contains ($rows | row 'test o> out').error 'cannot be called'
    assert not ($dir | path join out | path exists) 'no file was created by a redirection'
  }}

  {name: 'config: a symlinked project file counts' run: {||
    let dir = project {'cfgs/nutest.nuon': '{isolation: suite, env: {FROM_LINK: yes}}' 'tests/suites/p.nu': $PASSING}
    ^ln -s cfgs/nutest.nuon ($dir | path join nutest.nuon)
    let cfg = ok $dir 'test config'
    assert equal [$cfg.isolation $cfg.env] [suite {FROM_LINK: yes}]
  }}

  {name: 'config: timeout ends a hung child and is validated' run: {||
    if (which timeout | is-empty) { error make --unspanned {msg: 'SKIP: needs the timeout program'} }
    let dir = project {'nutest.nuon': '{timeout: 1sec}' 'tests/suites/h.nu': 'def "test hangs" [] { sleep 20sec }
def "test quick" [] { }'}
    let start = date now
    let rows = ok $dir 'test'
    assert ((date now) - $start < 12sec) 'the run did not wait for the sleep'
    assert equal ($rows | statuses) {'test hangs': error 'test quick': ok}
    assert str contains ($rows | row 'test hangs').error 'timed out after 1sec'
    assert str contains (runner $dir 'test --isolation suite' --vars {NU_TEST: '{timeout: -1sec}'}).stderr "invalid timeout"
  }}

  {name: 'config: a child that exits 124 on its own is not a timeout' run: {||
    let dir = project {'nutest.nuon': '{timeout: 30sec}' 'tests/suites/x.nu': 'def "test x" [] { exit 124 }'}
    let rows = ok $dir 'test'
    assert equal ($rows | statuses) {'test x': error}
    assert str contains ($rows | row 'test x').error 'exited with code 124'
    assert not (($rows | row 'test x').error =~ 'timed out') 'the exit code alone does not make a timeout'
  }}

  {name: 'config: a timeout without the timeout program warns instead of silently dropping the bound' run: {||
    let dir = project {'nutest.nuon': '{timeout: 1sec}' 'tests/suites/t.nu': 'def "test runs" [] { }'}
    # A PATH holding only `env` (the runner scrubs children with it; `nu` is started by its absolute path).
    let bin = $dir | path join bin
    mkdir $bin
    which --all env | where type == external | get --optional 0.path | each {|p| ^ln -s $p ($bin | path join env) }
    let res = runner $dir 'test' --vars {PATH: $bin}
    assert equal $res.exit_code 0 $res.stderr
    assert equal ($res.value | statuses) {'test runs': ok}
    assert str contains $res.stderr 'timeout 1sec is configured but no `timeout` program is on PATH'
    if (which timeout | is-not-empty) {
      assert not ((runner $dir 'test').stderr =~ 'no `timeout` program') 'nothing is said when the program is there'
    }
  }}

  {name: 'env: the scrub allowlist forwards custom XDG directories (what --no-sandbox relies on)' run: {||
    # `test exec` is never sandboxed, so what the child sees is what the KEEP allowlist let through.
    let dir = project {}
    let xdg = $dir | path join xdg
    mkdir ($xdg | path join nushell)
    let seen = ok $dir 'test exec "$env.XDG_DATA_HOME? | to nuon" --pipe' --vars {XDG_DATA_HOME: $xdg}
    assert equal $seen $xdg
  }}

  {name: 'hooks: contexts flow and after each runs after a failure (test isolation)' run: {||
    let dir = project {'tests/suites/h.nu': $HOOKED}
    let log = $dir | path join log.txt
    # Children start scrubbed, so the log path travels through the project file's `env`.
    $"{env: {LOG: ($log | to nuon)}}" | save --force ($dir | path join nutest.nuon)
    let rows = ok $dir 'test'
    assert equal ($rows | statuses) {'test sees contexts': ok 'test fails': fail}
    assert equal (open $log | lines) [all each after:2 done:1 all each after:2 done:1]
  }}

  {name: 'hooks: suite isolation runs before/after all once per suite' run: {||
    let dir = project {'tests/suites/h.nu': $HOOKED}
    let log = $dir | path join log.txt
    $"{env: {LOG: ($log | to nuon)}}" | save --force ($dir | path join nutest.nuon)
    let rows = ok $dir 'test --isolation suite'
    assert equal ($rows | statuses) {'test sees contexts': ok 'test fails': fail}
    assert equal (open $log | lines) [all each after:2 each after:2 done:1]
  }}

  {name: 'hooks: hook failures report as errors with the hook named' run: {||
    let dir = project {
      'tests/suites/ba.nu': 'def "before all" [] { error make --unspanned {msg: boom} }
def "test t" [] { }'
      'tests/suites/be.nu': 'def "before each" [] { error make --unspanned {msg: boom} }
def "test t" [] { }'
      'tests/suites/ae.nu': 'def "after each" [] { error make --unspanned {msg: boom} }
def "test t" [] { }'
      'tests/suites/aa.nu': 'def "after all" [] { error make --unspanned {msg: boom} }
def "test t" [] { }
def "test u" [] { }'
    }
    let rows = ok $dir 'test'
    let by = {|suite name| $rows | where suite == $suite and name == $name | first }
    assert equal (do $by ba 'test t' | select status error) {status: error error: 'before all failed: boom'}
    assert equal (do $by be 'test t' | select status error) {status: error error: 'before each failed: boom'}
    assert equal (do $by ae 'test t' | select status error) {status: error error: 'after each failed: boom'}
    assert equal (do $by aa 'test t').status ok
    # after all fails once per child, but is reported once.
    assert equal ($rows | where suite == aa and name == '(after all)' | select status error) [{status: error error: boom}]
    assert equal ((runner $dir 'test --match aa').stderr | split row '(after all)' | length) 2 'rendered once'
  }}

  {name: 'hooks: a skip raised in before all/before each skips the tests' run: {||
    let dir = project {
      'tests/suites/sa.nu': 'use test skip
def "before all" [] { skip "no tool" }
def "test t" [] { }'
      'tests/suites/se.nu': 'use test skip
def "before each" [] { skip "no creds" }
def "test t" [] { }'
    }
    let rows = ok $dir 'test'
    assert equal ($rows | select suite status error) [[suite status error]; [sa skip 'no tool'] [se skip 'no creds']]
  }}

  {name: 'crash: a child that exits reports its unfinished tests as errors' run: {||
    let dir = project {'tests/suites/c.nu': 'def "test a" [] { }
def "test b" [] { exit 3 }
def "test c" [] { }'}
    let suite = ok $dir 'test --isolation suite'
    assert equal ($suite | statuses) {'test a': ok 'test b': error 'test c': error}
    assert str contains ($suite | row 'test b').error 'exited with code 3'
    let isolated = ok $dir 'test'
    assert equal ($isolated | statuses) {'test a': ok 'test b': error 'test c': ok}
  }}

  {name: 'hooks: a hook name the runner cannot call blocks the suite with a reason' run: {||
    # A hook marked by attribute can carry a name the runner cannot write into the program: every test is reported
    # as an error naming the hook, and nothing runs.
    let dir = project {'tests/suites/u.nu': 'use std/testing *
@before-each
def "set && up" [] { }
def "test a" [] { }
def "test b" [] { }'}
    let rows = ok $dir 'test --isolation suite'
    assert equal ($rows | statuses) {'test a': error 'test b': error}
    for name in ['test a' 'test b'] {
      assert str contains ($rows | row $name).error "the hook 'set && up' cannot be called" $name
    }
    assert str contains (ok $dir 'test' | row 'test a').error 'cannot be called' 'the same under test isolation'
  }}

  {name: 'crash: a suite that fails to load is reported and the others still run' run: {||
    let dir = project {
      'tests/suites/broken.nu': 'def "test x" [] { ( }'
      'tests/suites/good.nu': $PASSING
    }
    let rows = ok $dir 'test'
    assert equal ($rows | select suite name status) [
      [suite name status];
      [broken '(discover)' error]
      [good 'test passes' ok]
    ]
  }}

  {name: 'paths: directories, files, mod.nu seams, depth, --match, --test' run: {||
    let dir = project {
      'tests/suites/one.nu': 'def "test a" [] { }
def "test b" [] { }'
      'tests/suites/mod.nu': 'def "test seam" [] { }'
      'tests/suites/sub/two.nu': 'def "test c" [] { }'
      'tests/suites/sub/x/y/four.nu': 'def "test d" [] { }'
    }
    assert equal (ok $dir 'test | get suite | uniq') [one two]
    assert equal (ok $dir 'test --depth 4 | get suite | uniq') [one two four]
    assert equal (ok $dir 'test --depth 1 | get suite | uniq') [one]
    assert equal (ok $dir 'test tests/suites/sub/two.nu | get name') ['test c']
    assert equal (ok $dir 'test tests/suites/sub --depth 5 | get suite | uniq') [two four]
    assert equal (ok $dir 'test --match "^t" | get suite | uniq') [two]
    assert equal (ok $dir 'test --test "b$" | get name') ['test b']
    let missing = runner $dir 'test nope/'
    assert not equal $missing.exit_code 0
    assert str contains $missing.stderr 'no such suite file or directory'
    let none = runner $dir 'test --match zzz'
    assert str contains $none.stderr 'no test suites matched'
    assert str contains $none.stderr "--match 'zzz'"
    mkdir ($dir | path join tests empty)
    let empty = runner $dir 'test tests/empty'
    assert str contains $empty.stderr 'no test suites matched'
    assert str contains $empty.stderr 'tests/empty' 'the searched path is named'
    assert not ($empty.stderr =~ '--match') 'the help cites --match only when it was given'
  }}

  {name: 'config: project file paths and lib-dirs resolve from its own directory' run: {||
    let dir = project {
      'nutest.nuon': '{paths: [checks], lib-dirs: [lib]}'
      'lib/greet/mod.nu': $GREET
      'checks/g.nu': 'use std/assert
use greet
def "test greet" [] { assert equal (greet hello) hi }'
      'elsewhere/.keep': ''
    }
    assert equal (ok $dir 'test' | statuses) {'test greet': ok}
    # From a subdirectory, the nearest project file above PWD supplies `paths`.
    assert equal (ok ($dir | path join checks) 'test' | statuses) {'test greet': ok}
    # From outside the project, the project file above the *suite* supplies lib-dirs.
    let suite = $dir | path join checks g.nu
    assert equal (ok ($dir | path join elsewhere) $"test ($suite | to nuon)" | statuses) {'test greet': ok}
    let cfg = ok $dir 'test config'
    assert equal $cfg.project ($dir | path join nutest.nuon)
    assert equal $cfg.paths [($dir | path join checks)]
    assert equal ($cfg.lib-dirs | first) ($dir | path join lib)
    assert equal ($cfg.lib-dirs | last) $ROOT
  }}

  {name: 'config: precedence defaults < $env.NU_TEST < project file < flags' run: {||
    let dir = project {'tests/suites/p.nu': $PASSING 'alt/q.nu': 'def "test q" [] { }'}
    assert equal (ok $dir 'test config | get isolation') test
    # $env.NU_TEST (record or nuon text) overrides the defaults, including where suites are found.
    assert equal (ok $dir 'with-env {NU_TEST: {isolation: suite paths: [alt]}} { test config } | get isolation') suite
    assert equal (ok $dir 'with-env {NU_TEST: "{paths: [alt]}"} { test } | get name') ['test q']
    # The project file overrides $env.NU_TEST; flags override both.
    '{isolation: test}' | save ($dir | path join nutest.nuon)
    assert equal (ok $dir 'with-env {NU_TEST: {isolation: suite}} { test config } | get isolation') test
    assert equal (ok $dir 'with-env {NU_TEST: {isolation: suite}} { test config --isolation suite } | get isolation') suite
    # lib-dirs accumulate, most specific first.
    '{lib-dirs: [from-project]}' | save --force ($dir | path join nutest.nuon)
    let libs = ok $dir 'with-env {NU_TEST: {lib-dirs: [/from-env]}} { test config -I [from-flag] } | get lib-dirs'
    assert equal $libs [($dir | path join from-flag) ($dir | path join from-project) /from-env $ROOT]
  }}

  {name: 'config: unknown keys and invalid values are rejected with the source named' run: {||
    let dir = project {'tests/suites/p.nu': $PASSING 'nutest.nuon': '{bogus: 1}'}
    let bad = runner $dir 'test'
    assert str contains $bad.stderr 'unknown test configuration key(s)'
    assert str contains $bad.stderr 'bogus'
    '{isolation: everything}' | save --force ($dir | path join nutest.nuon)
    assert str contains (runner $dir 'test').stderr "invalid isolation 'everything'"
    rm ($dir | path join nutest.nuon)
    assert str contains (runner $dir 'test --isolation everything').stderr "invalid isolation 'everything' in flags"
    assert str contains (runner $dir 'test --jobs 0').stderr "invalid jobs '0' in flags"
    # The keys the runner adds to a resolved configuration are unknown in a user's layer, not a crash.
    for layer in ['{resolved: true}' '{project: /x}'] {
      $layer | save --force ($dir | path join nutest.nuon)
      assert str contains (runner $dir 'test config').stderr 'unknown test configuration key(s)' $layer
    }
    rm ($dir | path join nutest.nuon)
    assert str contains (runner $dir 'test config' --vars {NU_TEST: '{resolved: true}'}).stderr 'unknown test configuration key(s) in $env.NU_TEST: resolved'
    # A complete resolved record (what a child receives) is still taken as is.
    assert equal (ok $dir 'let c = test config; with-env {NU_TEST: ($c | to nuon)} { test config } | get resolved') true
  }}

  {name: 'config: list and record keys are type-checked, an empty $env.NU_TEST counts as unset' run: {||
    let dir = project {'tests/suites/p.nu': $PASSING}
    for bad in [
      [layer key];
      ['{paths: tests/suites}' paths] ['{paths: [1 2]}' paths] ['{lib-dirs: lib}' lib-dirs]
      ['{passthrough: X}' passthrough] ['{passthrough: [1]}' passthrough] ['{env: foo}' env] ['{env: [A]}' env]
    ] {
      let res = runner $dir 'test config' --vars {NU_TEST: $bad.layer}
      assert not equal $res.exit_code 0 $bad.layer
      assert str contains $res.stderr $"invalid ($bad.key)" $bad.layer
      assert str contains $res.stderr 'in $env.NU_TEST' $bad.layer
    }
    '{env: foo}' | save --force ($dir | path join nutest.nuon)
    assert str contains (runner $dir 'test config').stderr 'invalid env' 'the project file is checked the same way'
    rm ($dir | path join nutest.nuon)
    # `NU_TEST= …` on a command line is no configuration, and nuon text must still read as a record.
    assert equal (ok $dir 'test' --vars {NU_TEST: ''} | statuses) {'test passes': ok}
    assert str contains (runner $dir 'test config' --vars {NU_TEST: '5'}).stderr '$env.NU_TEST must be a record, got int'
  }}

  {name: 'env: children start scrubbed; passthrough and env opt variables in' run: {||
    let dir = project {
      'nutest.nuon': '{passthrough: [KEEP_ME], env: {SET_ME: set}}'
      'tests/suites/e.nu': 'use std/assert
def "test leaked vars are hidden" [] { assert equal $env.LEAK? null }
def "test passthrough keeps a var" [] { assert equal $env.KEEP_ME kept }
def "test env sets a var" [] { assert equal $env.SET_ME set }
def "test the effective config is visible" [] { assert equal ($env.NU_TEST | from nuon | get resolved) true }'
    }
    let vars = {LEAK: leaked KEEP_ME: kept}
    assert equal (ok $dir 'test' --vars $vars | where status != ok) []
    let open = ok $dir 'test --no-scrub' --vars $vars
    assert equal ($open | row 'test leaked vars are hidden').status fail
  }}

  {name: 'env: grandchildren started from inside a test are scrubbed too (even after do --env)' run: {||
    let dir = project {
      'tests/suites/g.nu': 'use std/assert
use test
def "test exec after do --env hides the parent variables" [] {
  $env.INNER_LEAK = "leaked"
  do {
    do --env { }
    let seen = test exec "$env.INNER_LEAK? | default unset | to nuon" --pipe
    assert equal $seen unset
  }
}'
    }
    assert equal (ok $dir 'test' | statuses) {'test exec after do --env hides the parent variables': ok}
  }}

  {name: 'env: sandbox gives every child a throwaway HOME/XDG tree' run: {||
    let dir = project {
      'tests/suites/b.nu': 'use std/assert
use std-rfc/kv *
def "test home and data dirs live in a temp sandbox" [] {
  $nu.home-dir | save --append $env.LOG
  assert ($nu.data-dir | str starts-with $nu.home-dir)
  assert not equal $nu.home-dir $env.REAL_HOME
  kv set --universal written yes
  assert equal (kv get --universal written) yes
}'
    }
    let log = $dir | path join homes.txt
    {sandbox: true env: {LOG: $log REAL_HOME: $nu.home-dir}} | to nuon | save ($dir | path join nutest.nuon)
    assert equal (ok $dir 'test' | statuses) {'test home and data dirs live in a temp sandbox': ok}
    assert equal (open $log | path exists) false
    # The flag turns it off again (the project file sets it).
    assert equal (ok $dir 'test --no-sandbox' | statuses) {'test home and data dirs live in a temp sandbox': fail}
  }}

  {name: 'exec: tests can start configured grandchildren' run: {||
    let dir = project {
      'nutest.nuon': '{lib-dirs: [lib]}'
      'lib/greet/mod.nu': $GREET
      'tests/suites/x.nu': 'use std/assert
use test
def "test grandchild resolves the same modules" [] { assert equal (test exec "use greet; greet hello | to nuon" --pipe) hi }'
    }
    assert equal (ok $dir 'test' | statuses) {'test grandchild resolves the same modules': ok}
  }}

  {name: 'exec: complete record, --pipe, piped code, non-zero exit' run: {||
    let dir = project {}
    let res = ok $dir 'test exec "print hi"'
    assert equal [$res.stdout $res.exit_code] ["hi\n" 0]
    assert equal (ok $dir '"1 + 1 | to nuon" | test exec --pipe') 2
    let failed = runner $dir 'test exec "exit 4" --pipe'
    assert str contains $failed.stderr 'exited with code 4'
  }}

  {name: 'strict: raises only when something failed' run: {||
    let good = project {'tests/suites/p.nu': $PASSING}
    assert equal (runner $good 'test --strict').exit_code 0
    let bad = project {'tests/suites/s.nu': $STATUSES}
    let res = runner $bad 'test --strict'
    assert not equal $res.exit_code 0
    assert str contains $res.stderr '1 test(s) failed'
  }}

  {name: 'stdin: children cannot reach the terminal, so input-waiting tests end' run: {||
    let dir = project {'tests/suites/i.nu': 'use std/assert
def "test reading stdin gets nothing" [] { assert equal (try { input --numchar 1 } catch { "" } | default "") "" }'}
    if (which script timeout | length) < 2 { error make --unspanned {msg: 'SKIP: needs `script` and `timeout`'} }
    # Run the runner on a pseudo-terminal: a child that could reach the terminal would block in `input`.
    let cmd = $"timeout 15 '($nu.current-exe)' --no-config-file --include-path='($ROOT)' --commands 'use test; test | get status | to nuon'"
    # As `runner` does, drop a host `NU_TEST` (its `paths` would point the run elsewhere).
    let res = do { cd $dir; with-env {NU_TEST: null} { ^script -qec $cmd /dev/null | complete } }
    assert equal $res.exit_code 0 $'the run finishes instead of timing out: ($res.stdout)'
    assert str contains $res.stdout '[ok]' 'the test ran and passed'
  }}

  {name: 'skip: works in tests that receive a context' run: {||
    let dir = project {'tests/suites/k.nu': 'use test skip
def "before each" [] { {a: 1} }
def "test s" []: record -> nothing { skip "needs x" }'}
    assert equal (ok $dir 'test' | select name status error) [[name status error]; ['test s' skip 'needs x']]
  }}

  {name: 'sandbox: with-sandbox creates XDG dirs, cleans up, rethrows, and keeps SKIP' run: {||
    let dir = project {}
    let r = ok $dir 'test with-sandbox {|c| $c | insert existed {kv: ($c.data | path join nushell | path exists) code: ($c.code | path exists)} }'
    assert equal $r.existed {kv: true code: true}
    assert equal $r.home $r.root
    assert equal ($r.root | path exists) false
    let marker = $dir | path join root.txt
    let thrown = runner $dir $"test with-sandbox {|c| $c.root | save ($marker | to nuon); error make {msg: inner} }"
    assert str contains $thrown.stderr 'inner'
    assert equal (open $marker | path exists) false
    let suite = project {'tests/suites/w.nu': 'use test [skip with-sandbox]
def "test skipped inside a sandbox" [] { with-sandbox {|c| skip "nope" } }'}
    assert equal (ok $suite 'test' | select status error) [[status error]; [skip nope]]
  }}

  {name: 'sandbox: sandboxed points the child home and data dirs into the sandbox' run: {||
    let dir = project {}
    let r = ok $dir 'test with-sandbox {|c| test sandboxed $c "{home: $nu.home-dir, data: $nu.data-dir, extra: $env.EXTRA} | to nuon" --pipe --vars {EXTRA: x} | insert root $c.root }'
    assert equal $r.home $r.root
    assert equal $r.data ($r.root | path join .local share nushell)
    assert equal $r.extra x
  }}

  {name: 'colors: progress on stderr follows use_ansi_coloring' run: {||
    let dir = project {'tests/suites/p.nu': $PASSING}
    let plain = runner $dir '$env.config.use_ansi_coloring = false; test'
    assert equal $plain.exit_code 0 $plain.stderr
    assert not ($plain.stderr =~ '\e\[') $'no escape sequences when colours are off: ($plain.stderr)'
    assert str contains $plain.stderr '[ok] passes' 'the row renders plain'
    assert str contains $plain.stderr '1 passed, 0 failed, 0 skipped' 'the summary renders plain'
    let styled = runner $dir '$env.config.use_ansi_coloring = true; test'
    assert str contains $styled.stderr $"('[ok]' | style paint green --colors=true) passes" 'the ok marker is green when colours are on'
    assert str contains $styled.stderr ('1 passed' | style paint green --colors=true) 'the summary is coloured'
    # The default, `auto`, means "stdout is a terminal": the runner child here writes to a pipe.
    assert not ((runner $dir 'test').stderr =~ '\e\[') 'auto without a terminal is plain'
  }}

  {name: 'init: scaffolds a runnable layout, keeps existing files, --force overwrites' run: {||
    let dir = project {'lib/greet/mod.nu': $GREET}
    let made = ok $dir 'test init demo --module lib/greet'
    assert equal ($made | get action) [written written written]
    assert equal (open --raw ($dir | path join nutest.nuon) | from nuon) {paths: [tests/suites] lib-dirs: []}
    assert str contains (open --raw ($dir | path join tests mod.nu)) 'export use "../lib/greet"'
    assert equal (ok $dir 'test' | statuses) {'test demo works': ok}
    assert equal (ok $dir 'test init demo | get action') [kept kept kept]
    assert equal (ok $dir 'test init demo --force | get action') [written written written]
  }}
]}

# ——— runner ———————————————————————————————————————————————————————————————————

def main [
  filter?: string # Regex selecting which cases to run
]: nothing -> nothing {
  let selected: list = cases | where ($filter == null or $it.name =~ $filter)
  if ($selected | is-empty) {
    print --stderr $"no case matches '($filter)'; run without a filter to list the cases"
    exit 2
  }
  let results: list = $selected
    | each {|c|
      let start: datetime = date now
      let tmp: path = mktemp --directory --tmpdir nutest-selftest-XXXXXX
      let outcome: record = with-env {TMPDIR: $tmp} {
        try { do $c.run; {error: null} } catch {|e| {error: ($e.rendered? | default $e.msg) msg: $e.msg} }
      }
      rm --recursive --force $tmp
      let status: string = if $outcome.error == null { 'pass' } else if ($outcome.msg? | default '' | str starts-with 'SKIP: ') { 'skip' } else { 'FAIL' }
      let color: string = match $status { pass => 'green' skip => 'yellow' _ => 'red' }
      let note: string = if $status == skip { $" ($'— ($outcome.msg | str substring 6..)' | style paint attr_dimmed)" } else { '' }
      let took: string = $'(((date now) - $start) / 1sec | math round --precision 1)s'
      print $"($'[($status)]' | style paint $color) ($c.name) ($took | style paint attr_dimmed)($note)"
      {case: $c.name ok: ($status != 'FAIL') skipped: ($status == skip) error: (if $status == 'FAIL' { $outcome.error })}
    }
  let failed: list = $results | where not ok
  for f in $failed { print $"\n('FAIL' | style paint red) ($f.case)\n($f.error)" }
  print $"\n($results | length) cases, ($failed | length) failed, ($results | where skipped | length) skipped"
  if ($failed | is-not-empty) { exit 1 }
}
