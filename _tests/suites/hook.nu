# `hook` against the test child's own `$env.config.hooks`: `test _tests/suites/hook.nu`.
#
# Every test child starts with Nushell's default hooks (no config file): empty `pre_prompt`/`pre_execution`/
# `env_change`, the default `display_output` string and no `command_not_found`. Tests change hooks in their own
# scope only.
use hook
use ../mod.nu *

# Two pre_prompt hooks (an unnamed closure, a named record), a disabled pre_execution hook and a PWD hook.
def --env "before each" []: nothing -> nothing {
  hook add $.pre_prompt {|| 'plain' }
  hook add $.pre_prompt {name: named code: {|| 'named' }}
  hook add $.pre_execution {name: off disabled: true code: {|| 'off' }}
  hook add $.env_change.PWD {name: pwd condition: {|before after| $after == /x } code: {|before after| [$before $after] }}
}

# The names of the hooks of a type ('' for plain closures and text).
def names [type: cell-path]: nothing -> list<string> {
  hook $type | each {|h| match ($h | describe) { $d if $d starts-with record => ($h.name? | default '') _ => '' } }
}

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

# ——— export-env ———————————————————————————————————————————————————————————————

# Nushell refills `pre_prompt`/`pre_execution`/`env_change` itself on this nightly (`$env.config.hooks = {}` comes
# back filled, `null` is rejected), so the module's `export-env` cannot be told apart from Nushell's defaults here:
# this pins the shapes the module relies on, whichever of the two supplies them, even after a caller emptied the hooks.
def "test import leaves the list and record defaults in place" []: nothing -> nothing {
  with-sandbox {|ctx|
    let types = sandboxed $ctx '$env.config.hooks | select pre_prompt pre_execution env_change | record each {|k v| {($k): ($v | describe)} } | to nuon' --prelude '$env.config.hooks = {}; use hook' --pipe
    assert equal $types {pre_prompt: 'list<any>' pre_execution: 'list<any>' env_change: record} 'lists and a record'
  }
}

# ——— main —————————————————————————————————————————————————————————————————————

def "test main returns the hooks of a type" []: nothing -> nothing {
  assert equal (hook pre_prompt | length) 2 'both pre_prompt hooks'
  assert equal (hook pre_prompt 1 | get name) named 'by index'
  assert equal (hook pre_prompt 9) null 'an index out of range is null'
}

def "test main accepts a dotted text target" []: nothing -> nothing {
  assert equal (hook env_change.PWD | get name) [pwd] 'env_change.PWD as text (H2)'
  assert equal (hook $.env_change.PWD 0 | get name) pwd 'and as a cell-path'
}

def "test main raises for an unknown type" []: nothing -> nothing {
  let e = caught { hook nope }
  assert equal $e.msg "no hook configured at '$.nope'" 'names the target'
  assert equal $e.code 'hook::not_found' 'raised outside any def, so the code has no command segment, like main'
  assert error { hook env_change.NOPE } 'an unknown env_change variable too'
}

# ——— is-enabled ———————————————————————————————————————————————————————————————

def "test is enabled by reference" []: nothing -> nothing {
  assert (hook is-enabled $.pre_prompt.1) 'a hook without disabled is enabled'
  assert not (hook is-enabled $.pre_execution.0) 'disabled: true'
  assert (hook is-enabled $.pre_prompt.9) 'a missing hook counts as enabled'
  assert equal (caught { hook is-enabled $.pre_prompt.9 --strict }).code 'hook::show::not_found' 'unless --strict: the lookup raises'
}

def "test is enabled by name" []: nothing -> nothing {
  assert (hook is-enabled --name=named) 'enabled'
  assert not (hook is-enabled --name=off) 'disabled hooks are found by name too'
  assert (hook is-enabled --name=nope) 'a missing name counts as enabled'
  assert error { hook is-enabled --name=nope --strict } 'unless --strict'
}

def "test is enabled needs a reference or a name" []: nothing -> nothing {
  let e = caught { hook is-enabled }
  assert equal $e.msg 'a ref or --name is required' 'H4'
  assert equal $e.code 'hook::is-enabled::invalid_argument' 'the derived code'
  assert str contains $e.help 'cell-path' 'the advice says what to pass'
}

# ——— with —————————————————————————————————————————————————————————————————————

def "test with modifies the hook only inside the closure" []: nothing -> nothing {
  let inside: bool = hook with --name=named {disabled: true} {|| hook is-enabled --name=named }
  assert not $inside 'disabled inside'
  assert (hook is-enabled --name=named) 'enabled again afterwards'
}

def "test with by reference" []: nothing -> nothing {
  let inside = hook with --hook=$.pre_prompt.1 {disabled: true extra: 1} {|| hook pre_prompt 1 | select disabled extra }
  assert equal $inside {disabled: true extra: 1} 'any record is merged'
  assert equal (hook pre_prompt 1 | columns) [name code] 'unchanged afterwards'
}

def "test with root runs the closure there" []: nothing -> nothing {
  with-sandbox {|ctx|
    let before: path = $env.PWD
    assert equal (hook with --name=named --root=$ctx.code {disabled: true} {|| $env.PWD }) $ctx.code 'inside the root'
    assert equal $env.PWD $before 'the caller stays put'
  }
}

def "test with loads piped input into the environment" []: nothing -> nothing {
  assert equal ({GREETING: hi} | hook with --name=named {disabled: true} {|| $env.GREETING }) hi 'the record becomes env'
}

def "test with runs the closure when the hook does not resolve" []: nothing -> nothing {
  assert equal (hook with --name=nope {disabled: true} {|| 'ran' }) ran 'missing name (H5)'
  assert equal (hook with --hook=$.pre_prompt.9 {disabled: true} {|| 'ran' }) ran 'missing reference'
}

def "test with strict raises when the hook does not resolve" []: nothing -> nothing {
  let name = caught { hook with --name=nope --strict {disabled: true} {|| 'ran' } }
  assert equal $name.code 'hook::list::not_found' 'a missing name fails in the lookup by name'
  let ref = caught { hook with --hook=$.pre_prompt.9 --strict {disabled: true} {|| 'ran' } }
  assert equal $ref.msg "no hook at '$.pre_prompt.9'" 'a missing reference is named'
  assert equal $ref.code 'hook::with::not_found' 'the derived code'
}

def "test with needs a name or a reference" []: nothing -> nothing {
  let e = caught { hook with {disabled: true} {|| 'ran' } }
  assert equal $e.msg 'either a name or reference is required' 'the error'
  assert equal $e.code 'hook::with::invalid_argument' 'the derived code'
}

def "test with refuses a single valued hook" []: nothing -> nothing {
  let by_ref = caught { hook with --hook=$.display_output {disabled: true} {|| 'ran' } }
  assert equal $by_ref.code 'hook::edit::invalid_argument' 'the edit raises before the closure runs'
  let by_name = caught { hook with --name=display_output {disabled: true} {|| 'ran' } }
  assert equal $by_name.code 'hook::edit::invalid_argument' 'by name too'
  assert equal (hook list | where name == display_output | length) 1 'the hook is untouched and still listable'
}

# ——— reference, show, list ————————————————————————————————————————————————————

def "test reference finds named and unnamed hooks" []: nothing -> nothing {
  assert equal (hook reference named) $.pre_prompt.1 'a named record'
  assert equal (hook reference 'pre_prompt[0]') $.pre_prompt.0 'an unnamed hook by its synthetic name'
  assert equal (hook reference pwd) $.env_change.PWD.0 'env_change hooks'
  assert equal (hook reference nope) null 'missing'
  assert error { hook reference nope --strict } 'missing with --strict'
}

def "test show serializes closures" []: nothing -> nothing {
  let h = hook show $.pre_prompt.0
  assert equal ($h | select name code disabled ref) {name: 'pre_prompt[0]' code: "{|| 'plain' }" disabled: false ref: $.pre_prompt.0} 'the flattened hook'
  assert equal $h.condition '{|| is-enabled $ref }' 'an unnamed closure gets an is-enabled condition'
  assert equal (hook show $.pre_prompt.0 --raw | get code | describe) closure '--raw keeps the closure'
}

def "test show selects a cell and defaults" []: nothing -> nothing {
  assert equal (hook show $.pre_prompt.1 $.name) named 'one field'
  assert equal (hook show $.pre_prompt.9) null 'a missing hook is null'
  assert equal (hook show $.pre_prompt.9 --default=x) x 'or the default'
  assert equal (hook show $.pre_prompt.1 $.nope --default=x) x 'a missing field too'
  let e = caught { hook show $.pre_prompt.9 --strict }
  assert equal $e.msg "no hook at '$.pre_prompt.9'" 'strict raises'
  assert equal $e.code 'hook::show::not_found' 'the derived code'
  assert equal ($e.labels | get text) [reference] 'the reference is labelled'
}

def "test list flattens the enabled hooks" []: nothing -> nothing {
  let names: list<string> = hook list | get name
  assert equal $names ['pre_prompt[0]' named pwd display_output] 'every type, the disabled one left out'
  assert equal (hook list | where name == pwd | get ref) [$.env_change.PWD.0] 'with references'
}

def "test list by name includes disabled hooks" []: nothing -> nothing {
  assert equal (hook list off named | get name | sort) [named off] 'named hooks, disabled or not'
  assert equal (hook list nope) [] 'nothing for an unknown name'
  let e = caught { hook list nope other --strict }
  assert equal $e.msg "no hook named 'nope', 'other'" 'unless --strict: every name is listed'
  assert equal $e.code 'hook::list::not_found' 'the derived code'
  assert equal ($e.labels | get text) ['name(s)'] 'the names are labelled'
}

# ——— edit, del ————————————————————————————————————————————————————————————————

def "test edit update merges a record" []: nothing -> nothing {
  let h = hook edit $.pre_prompt.1 --update {disabled: true}
  assert equal ($h | select name disabled) {name: named disabled: true} 'returns the edited hook'
  assert not (hook is-enabled --name=named) 'and stores it'
}

def "test edit update turns a bare closure hook into a record" []: nothing -> nothing {
  let h = hook edit $.pre_prompt.0 --update {disabled: true}
  assert (($h | describe) starts-with record) 'the bare closure became a record'
  assert equal $h.disabled true 'with the update applied'
  assert equal ($h.code | describe) closure 'and the closure kept as code'
  assert equal (hook with --name 'pre_prompt[0]' {disabled: false} {|| 'ran' }) ran '`with` works on it too'
}

def "test edit overwrite stores a closure" []: nothing -> nothing {
  hook edit $.pre_prompt.0 --overwrite {|| 7 } | ignore
  assert equal (hook pre_prompt 0 | describe) closure 'the closure, not its result (H1)'
  assert equal (hook test $.pre_prompt.0) 7 'which still runs'
}

def "test edit overwrite stores text and records" []: nothing -> nothing {
  hook edit $.pre_prompt.0 --overwrite 'print hi' | ignore
  assert equal (hook pre_prompt 0) 'print hi' 'text'
  hook edit $.pre_prompt.0 --overwrite {condition: {|| false } code: 'x'} | ignore
  assert equal (hook pre_prompt 0 | get code) x 'a record'
}

def "test edit errors" []: nothing -> nothing {
  let none = caught { hook edit $.pre_prompt.0 }
  assert equal $none.msg 'no overwrite value or update record was given' 'no flag'
  assert equal $none.code 'hook::edit::invalid_argument' 'the derived code'
  let missing = caught { hook edit $.pre_prompt.9 --update {disabled: true} }
  assert equal $missing.msg "no hook at '$.pre_prompt.9'" 'missing reference'
  assert equal $missing.code 'hook::edit::not_found' 'the derived code'
  assert equal (caught { hook edit $.pre_prompt.9 --overwrite 'x' }).code 'hook::edit::not_found' 'overwrite needs an existing hook too'
}

def "test edit update refuses a single valued hook" []: nothing -> nothing {
  let e = caught { hook edit $.display_output --update {disabled: true} }
  assert equal $e.msg "the hook at '$.display_output' holds a single closure or string, not a record" 'display_output holds no record'
  assert equal $e.code 'hook::edit::invalid_argument' 'the derived code'
  assert str contains $e.help '--overwrite' 'the advice names the remedy'
  hook add $.command_not_found {|cmd| null }
  assert equal (caught { hook edit $.command_not_found --update {disabled: true} }).code 'hook::edit::invalid_argument' 'command_not_found too'
  assert equal (hook list | get name) ['pre_prompt[0]' named pwd display_output command_not_found] 'both are untouched and still listable'
}

def "test edit refuses a hook list" []: nothing -> nothing {
  for ref in [$.pre_prompt $.env_change.PWD $.env_change] {
    let e = caught { hook edit $ref --update {disabled: true} }
    assert equal $e.msg $"'($ref)' is a list of hooks, not one hook" $'a list is not one hook: ($ref)'
    assert equal $e.code 'hook::edit::invalid_argument' 'the derived code'
    assert str contains $e.help '$.pre_prompt.0' 'the advice shows an entry reference'
    assert equal (caught { hook edit $ref --overwrite {|| 1 } }).code 'hook::edit::invalid_argument' 'overwrite too'
  }
  assert equal (hook list | get name) ['pre_prompt[0]' named pwd display_output] 'nothing changed'
}

def "test with refuses a hook list" []: nothing -> nothing {
  for ref in [$.pre_prompt $.env_change.PWD] {
    assert equal (caught { hook with --hook=$ref {disabled: true} {|| 'ran' } }).code 'hook::edit::invalid_argument' $'the edit raises before the closure runs: ($ref)'
  }
  assert equal (hook list | get name) ['pre_prompt[0]' named pwd display_output] 'nothing changed'
}

def "test edit overwrite replaces a single valued hook" []: nothing -> nothing {
  hook edit $.display_output --overwrite 'table' | ignore
  assert equal (hook display_output) table 'text'
  hook edit $.display_output --overwrite {|| table } | ignore
  assert equal (hook show $.display_output $.code --raw | describe) closure 'a closure, still listable'
}

def "test del removes a hook" []: nothing -> nothing {
  assert (hook del $.pre_prompt.0) 'removed'
  assert equal (hook pre_prompt | get name) [named] 'the other one remains'
  assert not (hook del $.pre_prompt.9) 'nothing to remove'
}

# ——— test —————————————————————————————————————————————————————————————————————

def "test test runs code and conditions" []: nothing -> nothing {
  assert equal (hook test $.env_change.PWD.0 /a /b) [/a /b] 'code with arguments'
  assert (hook test $.env_change.PWD.0 --condition /a /x) 'the condition'
  assert not (hook test $.env_change.PWD.0 --condition /a /y) 'the condition, false'
  assert equal (hook test $.pre_prompt.1) named 'no arguments'
}

def "test test passes input" []: nothing -> nothing {
  hook add $.pre_prompt {|| $in + 1 }
  assert equal (hook test $.pre_prompt.2 --input 41) 42 'closure input'
}

def "test test runs text code in a child interpreter" []: nothing -> nothing {
  hook add $.pre_prompt '$in.n * 2 | print'
  assert equal (hook test $.pre_prompt.2 --input {n: 21} | str trim) '42' 'the input arrives as nuon'
}

def "test test raises without code or condition" []: nothing -> nothing {
  let code = caught { hook test $.pre_prompt.9 }
  assert equal $code.msg "no hook code at '$.pre_prompt.9'" 'missing code'
  assert equal $code.code 'hook::test::not_found' 'the derived code'
  assert equal ($code.labels | get text) [reference] 'the reference is labelled'
  let cond = caught { hook test $.pre_prompt.1 --condition }
  assert equal $cond.msg "no hook condition at '$.pre_prompt.1'" 'missing condition'
}

# ——— add ——————————————————————————————————————————————————————————————————————

def "test add appends by default" []: nothing -> nothing {
  hook add $.pre_prompt {name: last code: {|| 3 }}
  assert equal (names $.pre_prompt) ['' named last] 'appended'
}

def "test add inserts at an index" []: nothing -> nothing {
  hook add $.pre_prompt --index 0 {name: first code: {|| 0 }}
  hook add $.pre_prompt --index -2 {name: second-to-last code: {|| 0 }}
  assert equal (names $.pre_prompt) [first '' second-to-last named] '0 prepends; -2 goes before the last'
}

def "test add takes a piped list" []: nothing -> nothing {
  [{name: a code: {|| 1 }} {name: b code: {|| 2 }}] | hook add $.pre_execution {name: c code: {|| 3 }}
  assert equal (hook pre_execution | get name) [off a b c] 'input first, then the value'
}

def "test add without a value does nothing" []: nothing -> nothing {
  hook add $.pre_prompt
  assert equal (hook pre_prompt | length) 2 'unchanged'
}

def "test add creates an env change list" []: nothing -> nothing {
  hook add $.env_change.FOO {|before after| 1 }
  assert equal (hook env_change.FOO | length) 1 'new variable'
}

def "test add dedupe skips registered names" []: nothing -> nothing {
  hook add --dedupe $.pre_prompt {name: named code: {|| 'again' }}
  hook add --dedupe $.pre_execution {name: off code: {|| 'again' }}
  hook add --dedupe $.pre_prompt {name: fresh code: {|| 1 }}
  assert equal (names $.pre_prompt) ['' named fresh] 'only the new name'
  assert equal (hook pre_execution | length) 1 'a disabled hook counts as registered'
}

def "test add refuses an entry reference" []: nothing -> nothing {
  for target in [$.pre_prompt.0 $.env_change.PWD.0 $.nope] {
    let e = caught { hook add $target {|| 2 } }
    assert equal $e.msg $"'($target)' is not a hook type or an env_change variable" $'not a list to add to: ($target)'
    assert equal $e.code 'hook::add::invalid_argument' 'the derived code'
  }
  assert equal (hook pre_prompt | length) 2 'nothing was added'
  assert (hook pre_prompt | all ($it | describe) !~ '^list') 'and no list was nested into the hooks'
  assert equal (hook env_change.PWD | length) 1 'env_change lists neither'
}

def "test add replaces a single valued hook" []: nothing -> nothing {
  hook add $.display_output 'table -e'
  assert equal (hook display_output) 'table -e' 'the new value wins (H3)'
  hook add $.display_output --index 0 'table'
  assert equal (hook display_output) 'table' 'whatever the index'
  hook add $.command_not_found {|cmd| null }
  assert equal (hook command_not_found | describe) closure 'a closure is stored as is'
  hook add $.display_output {|| table }
  assert equal (hook display_output | describe) closure 'for display_output too'
}
