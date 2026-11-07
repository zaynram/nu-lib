# `error raise`: `test _tests/suites/error.nu`.
#
# Codes are derived from the raise site, so a raise written in this suite file derives the namespace
# `_tests::suites::error` (the file's path under the repository root) and the test's own name as the command.
# Derivation from other layouts runs fixture module trees under a sandbox in a child interpreter.
use error
use ../fixtures/error/raiser.nu
use ../mod.nu *

# The namespace every raise written in this file derives.
const HERE: string = '_tests::suites::error'

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

# Write `files` (path relative to the fixture library → text) under the sandbox and return the library directory.
def write-lib [ctx: record files: record]: nothing -> path {
  let lib: path = $ctx.code | path join lib
  $files | items {|relative text|
    let file: path = $lib | path join $relative
    mkdir ($file | path dirname)
    $text | save --force $file
  }
  $lib
}

# The error details a child interpreter prints as nuon when it runs `program` (or the `--script` file), with the
# repository and `lib` on its include path.
def run-nu [lib: oneof<nothing, path> program?: string --script: path]: nothing -> record {
  let include: string = [$ROOT $lib] | compact | str join (char esep)
  let target: list<string> = if $script != null { [$script] } else { [--commands $program] }
  let launch: list<string> = [--no-config-file --error-style=plain $"--include-path=($include)" ...$target]
  let res: record = '' | run-external $nu.current-exe ...$launch | complete
  if $res.exit_code != 0 { error make --unspanned {msg: 'the child interpreter failed' help: $res.stderr} }
  $res.stdout | from nuon
}

# The details of the error `code` raises in a child interpreter (`lib` is on its include path; `error` is imported).
def child-raise [lib: oneof<nothing, path> code: string]: nothing -> record {
  run-nu $lib $"use error\ntry { ($code) } catch {|e| print \($e.details | to nuon) }"
}

# ——— derivation in this file ———————————————————————————————————————————————————

def "test raise derives its code from the file path and the enclosing def" []: nothing -> nothing {
  let e = caught { error raise 'it broke' }
  assert equal $e.msg 'it broke' 'the message'
  assert equal $e.code $'($HERE)::test-raise-derives-its-code-from-the-file-path-and-the-enclosing-def::internal' 'namespace, command with dashes, default kind'
  assert equal $e.help null 'no help'
  assert equal $e.labels [] 'unspanned'
  assert equal $e.inner [] 'no inner error without input'
}

def "test raise with a kind" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --kind not_found }
  assert equal $e.code $'($HERE)::test-raise-with-a-kind::not_found' 'the kind is the last segment'
}

def "test raise accepts every documented kind" []: nothing -> nothing {
  let kinds = [invalid_argument not_found unsupported missing_dependency external_failure conflict io internal]
  assert equal $error.KINDS $kinds 'the vocabulary is fixed'
  # `each` feeds the kind to `caught` as pipeline input, which `do` would hand to the raise; a raise ignores input
  # that is not an error record, so the `null` only keeps the raise input-free.
  let codes = $kinds | each {|k| null | caught { error raise 'it broke' --kind $k } | get $.code }
  assert equal $codes ($kinds | each { $'($HERE)::test-raise-accepts-every-documented-kind::($in)' }) 'each kind ends the code'
}

def "test raise rejects an unknown kind" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --kind bogus }
  assert equal $e.code 'error::raise::invalid_argument' 'the error module names its own error'
  assert equal $e.msg "unknown error kind 'bogus'" 'the message names the kind'
  assert str contains ($e.labels | get $.0.text) 'not_found, unsupported' 'the label lists the kinds'
}

def "test raise inside a default closure names the enclosing command" []: nothing -> nothing {
  let e = caught { null | default { error raise 'a value is required' --kind invalid_argument } }
  assert equal $e.code $'($HERE)::test-raise-inside-a-default-closure-names-the-enclosing-command::invalid_argument' 'the def, not the closure'
}

def "test raise with a message built in the same command" []: nothing -> nothing {
  let e = caught { let msg = $"built from (1 + 1) parts"; error raise $msg --kind io }
  assert equal $e.code $'($HERE)::test-raise-with-a-message-built-in-the-same-command::io' 'the span of the interpolation is in this def'
}

def "test raise with a message from another command derives that command" []: nothing -> nothing {
  let e = caught { error raise (message-from-elsewhere) }
  assert equal $e.code $'($HERE)::message-from-elsewhere::internal' 'the span of the message decides, hence --with {code} for such messages'
}

# A message whose span lies in this command, not at the raise site.
def message-from-elsewhere []: nothing -> string { 'made elsewhere' }

def "test raise from a module under the repository root" []: nothing -> nothing {
  assert equal (caught { raiser go }).code '_tests::fixtures::error::raiser::go::not_found' 'the path under the root, then the def'
}

# ——— overrides and the other details ———————————————————————————————————————————

def "test raise with a code" []: nothing -> nothing {
  let e = caught {
    error raise 'it broke' --with={
      code: 'mymod::ctx::kind'
      kind: not_found
    }
  }
  assert equal $e.code 'mymod::ctx::kind' 'the code replaces the derived one'
}

def "test raise with an empty code has no code" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --with={code: ''} }
  assert equal $e.code null 'an empty code is not derived, it is left out'
}

def "test raise with help" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --with={help: 'try again'} }
  assert equal $e.help 'try again' 'the help is passed through'
}

def "test raise leaves out empty help" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --with={help: ''} }
  assert equal $e.help null 'an empty string is compacted away'
}

def "test raise with a kind in with derives the code and wins over the flag" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --kind io --with={kind: not_found help: 'look elsewhere'} }
  assert equal $e.code $'($HERE)::test-raise-with-a-kind-in-with-derives-the-code-and-wins-over-the-flag::not_found' 'derived with the kind from --with'
  assert equal $e.help 'look elsewhere' 'and the rest of the details'
  let bad = caught { error raise 'it broke' --with={kind: bogus} }
  assert equal $bad.code 'error::raise::invalid_argument' 'a kind from --with is validated too'
}

def "test raise rejects a key error make would drop" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --with={kind: io advice: 'try again'} }
  assert equal $e.code 'error::raise::invalid_argument' 'not a silent loss'
  assert equal $e.msg "unknown --with key 'advice'" 'the key is named'
  assert str contains $e.help 'help' 'the help names the accepted keys'
}

def "test raise wraps a record input as the inner error" []: nothing -> nothing {
  let e = caught { {msg: 'the cause'} | error raise 'it broke' }
  assert equal ($e.inner | get $.msg) ['the cause'] 'one inner error'
}

def "test raise ignores pipeline input that is not an error" []: nothing -> nothing {
  for input in [[1 2] 'text' {name: no-msg-here} 42] {
    let e: record = caught {|| $input | error raise 'the message' }
    assert equal $e.inner [] $'no inner for input ($input | describe)'
    assert equal $e.msg 'the message' 'and the raise itself works'
  }
}

def "test raise wraps a caught error as the inner error" []: nothing -> nothing {
  let cause = try { error make --unspanned {msg: 'the config file could not be read' help: 'the help of the cause'} } catch {|e| $e }
  let e = caught { $cause | error raise 'it broke' }
  assert equal ($e.inner | get $.msg) ['the config file could not be read'] 'the caught error'
  assert equal ($e.inner | get $.help) ['the help of the cause'] 'with its details'
}

def "test raise with labels returns a closure" []: nothing -> nothing {
  let span = (metadata 'here').span
  let raiser = error raise 'it broke' --with={
    kind: conflict
    labels: [{text: 'right here' span: $span}]
  }
  assert equal ($raiser | describe) closure 'nothing is raised yet'
  let e = caught $raiser
  assert equal $e.msg 'it broke' 'the closure raises the error'
  assert equal ($e.labels | get $.text) ['right here'] 'with the labels'
  assert equal ($e.labels | get $.span) [$span] 'and their spans'
  assert equal $e.code $'($HERE)::test-raise-with-labels-returns-a-closure::conflict' 'and the code derived where the closure was made'
}

def "test raise with labels keeps the inner error" []: nothing -> nothing {
  let cause = {msg: 'the cause'}
  let raiser = $cause | error raise 'it broke' {text: x span: (metadata 'x').span}
  assert equal ((caught $raiser).inner | get $.msg) ['the cause'] 'the input is captured by the closure'
}

def "test raise takes labels as arguments, a label or labels in with, and counts them all" []: nothing -> nothing {
  let a = {text: a span: (metadata 'a').span}
  let b = {text: b span: (metadata 'b').span}
  let c = {text: c span: (metadata 'c').span}
  assert equal ((caught (error raise 'one' $a)).labels | get $.text) [a] 'a rest argument'
  assert equal ((caught (error raise 'one' --with={label: $b})).labels | get $.text) [b] 'a single label in --with'
  assert equal ((caught (error raise 'two' --with={labels: [$b $c]})).labels | get $.text) [b c] 'labels in --with'
  let all = caught (error raise 'three' --with={label: $a labels: [$b]} $c)
  assert equal ($all.labels | get $.text) [a b c] 'all of them, --with first'
  assert equal ($all.labels | get $.span) [$a.span $b.span $c.span] 'with their spans intact'
}

def "test throw raises a labelled error in the caller" []: nothing -> nothing {
  let e = caught { error raise 'thrown' --kind conflict {text: here span: (metadata 'here').span} | error throw }
  assert equal [$e.msg ($e.labels | get $.text)] [thrown [here]] 'the closure is raised'
  assert equal $e.code $'($HERE)::test-throw-raises-a-labelled-error-in-the-caller::conflict' 'with the code derived at the raise'
}

def "test raise keeps every error record of a list input" []: nothing -> nothing {
  let e = caught { [{msg: first} 'not an error' {msg: second}] | error raise 'it broke' }
  assert equal ($e.inner | get $.msg) [first second] 'one inner error per error record'
}

def "test raise unwraps a record that holds only inner errors" []: nothing -> nothing {
  let e = caught { {inner: [{msg: 'deep cause'} {msg: 'ignored'}]} | error raise 'it broke' }
  assert equal ($e.inner | get $.msg) ['deep cause'] 'its first inner error'
}

def "test raise keeps the code of a caught inner error" []: nothing -> nothing {
  let cause = try { error raise 'the cause' --kind not_found } catch {|e| $e }
  let e = caught { $cause | error raise 'it broke' }
  assert equal ($e.inner | get $.code) [$'($HERE)::test-raise-keeps-the-code-of-a-caught-inner-error::not_found'] 'the details of the caught error, code included'
}

# ——— derivation from fixture module trees ——————————————————————————————————————

def "test raise in a top level module derives the module name" []: nothing -> nothing {
  with-sandbox {|ctx|
    let lib = write-lib $ctx {'top/mod.nu': "use error\nexport def go [] { error raise 'top' --kind not_found }"}
    assert equal (child-raise $lib 'use top; top go').code 'top::go::not_found' 'directory, def, kind'
  }
}

def "test raise in a nested module joins the directories" []: nothing -> nothing {
  with-sandbox {|ctx|
    let lib = write-lib $ctx {'x/local/mod.nu': "use error\nexport def go [] { error raise 'nested' }"}
    assert equal (child-raise $lib 'use x/local; local go').code 'x::local::go::internal' 'every directory under the root'
  }
}

def "test raise in a file that is not mod.nu adds the stem" []: nothing -> nothing {
  with-sandbox {|ctx|
    let lib = write-lib $ctx {'x/y.nu': "use error\nexport def go [] { error raise 'not mod' --kind conflict }"}
    assert equal (child-raise $lib 'use x/y.nu; y go').code 'x::y::go::conflict' 'the stem is a segment'
  }
}

def "test raise honours the error-namespace directive" []: nothing -> nothing {
  with-sandbox {|ctx|
    let text = "# nu-lint-ignore-file: unused_parameter\n# error-namespace: custom::space\nuse error\nexport def go [] { error raise 'overridden' }"
    let lib = write-lib $ctx {'over/mod.nu': $text}
    assert equal (child-raise $lib 'use over; over go').code 'custom::space::go::internal' 'the directive replaces the path'
  }
}

def "test raise in a quoted multi word command joins the words with dashes" []: nothing -> nothing {
  with-sandbox {|ctx|
    let text = [
      'use error'
      "export def --env \"win env\" [] { error raise 'words' --kind unsupported }"
      "export def --wrapped 'single quoted' [...rest] { error raise 'quoted' }"
    ] | str join (char newline)
    let lib = write-lib $ctx {'words/mod.nu': $text}
    assert equal (child-raise $lib 'use words; words win env').code 'words::win-env::unsupported' 'double quotes, def --env'
    assert equal (child-raise $lib 'use words; words single quoted').code 'words::single-quoted::internal' 'single quotes, def --wrapped'
  }
}

def "test raise in main omits the command" []: nothing -> nothing {
  with-sandbox {|ctx|
    let lib = write-lib $ctx {'top/mod.nu': "use error\nexport def main [] { error raise 'main' --kind io }"}
    assert equal (child-raise $lib 'use top; top').code 'top::io' 'namespace and kind only'
  }
}

def "test raise outside any def omits the command" []: nothing -> nothing {
  with-sandbox {|ctx|
    let text = "use error\ntry { error raise 'bare' --kind external_failure } catch {|e| print ($e.details | to nuon) }"
    let lib = write-lib $ctx {'script.nu': $text}
    assert equal (run-nu $lib --script ($lib | path join script.nu)).code 'script::external_failure' 'a script under the root: its stem, no command'
  }
}

def "test raise outside any def that follows one is attributed to that def" []: nothing -> nothing {
  # The documented approximation (_docs/errors.md): the command is the last `def` line before the raise, so an alias
  # or `export-env` block placed after the defs names the last def; `--with {code}` is the remedy there.
  with-sandbox {|ctx|
    let late = [
      'use error'
      'export def go [] { }'
      "export alias boom = do { error raise 'late' --kind conflict }"
      "export alias fixed = do { error raise 'late' --with={code: 'late::conflict'} }"
    ] | str join (char newline)
    let early = "use error\nexport alias boom = do { error raise 'early' --kind conflict }\nexport def go [] { }"
    let lib = write-lib $ctx {'late/mod.nu': $late 'early/mod.nu': $early}
    assert equal (child-raise $lib 'use late; late boom').code 'late::go::conflict' 'after a def: the def is named'
    assert equal (child-raise $lib 'use late; late fixed').code 'late::conflict' '--with {code} gives the intended code'
    assert equal (child-raise $lib 'use early; early boom').code 'early::conflict' 'before the first def: no command'
  }
}

def "test raise in the root mod.nu is named after the root directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    let lib = write-lib $ctx {'mod.nu': "use error\nexport def go [] { error raise 'root' }"}
    assert equal (child-raise $lib $"use ($lib)/mod.nu; mod go").code 'lib::go::internal' 'no path under the root, so the root itself'
  }
}

def "test raise in a file outside the library roots uses its stem" []: nothing -> nothing {
  with-sandbox {|ctx|
    let script = $ctx.code | path join standalone.nu
    "use error\ndef go [] { error raise 'standalone' --kind missing_dependency }\ntry { go } catch {|e| print ($e.details | to nuon) }" | save $script
    assert equal (run-nu null --script $script).code 'standalone::go::missing_dependency' 'the stem alone, then the def'
  }
}

def "test raise from code given on the command line uses the nu namespace" []: nothing -> nothing {
  let e = child-raise null "error raise 'not in a file' --kind not_found"
  assert equal $e.code 'nu::not_found' 'no file: nu, no command'
}

def "test raise from a def given on the command line still uses the nu namespace" []: nothing -> nothing {
  let e = child-raise null "def go [] { error raise 'not in a file' }; go"
  assert equal $e.code 'nu::internal' 'no file: the def is not reported either'
}
