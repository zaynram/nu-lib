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

# ——— export-env ———————————————————————————————————————————————————————————————

def "test import provides the list and record defaults" []: nothing -> nothing {
  with-sandbox {|ctx|
    let types = sandboxed $ctx '$env.config.hooks | select pre_prompt pre_execution env_change | items {|k v| {($k): ($v | describe)} } | into record | to nuon' --prelude 'use hook' --pipe
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
  let msg: string = try { hook nope; 'no error' } catch {|e| $e.msg }
  assert equal $msg 'hook not found: $.nope' 'names the target'
  assert error { hook env_change.NOPE } 'an unknown env_change variable too'
}

# ——— is-enabled ———————————————————————————————————————————————————————————————

def "test is enabled by reference" []: nothing -> nothing {
  assert (hook is-enabled $.pre_prompt.1) 'a hook without disabled is enabled'
  assert not (hook is-enabled $.pre_execution.0) 'disabled: true'
  assert (hook is-enabled $.pre_prompt.9) 'a missing hook counts as enabled'
  assert error { hook is-enabled $.pre_prompt.9 --strict } 'unless --strict'
}

def "test is enabled by name" []: nothing -> nothing {
  assert (hook is-enabled --name=named) 'enabled'
  assert not (hook is-enabled --name=off) 'disabled hooks are found by name too'
  assert (hook is-enabled --name=nope) 'a missing name counts as enabled'
  assert error { hook is-enabled --name=nope --strict } 'unless --strict'
}

def "test is enabled needs a reference or a name" []: nothing -> nothing {
  let msg: string = try { hook is-enabled; 'no error' } catch {|e| $e.msg }
  assert equal $msg 'a ref or --name is required' 'H4'
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
  assert error { hook with --name=nope --strict {disabled: true} {|| 'ran' } } 'missing name'
  assert error { hook with --hook=$.pre_prompt.9 --strict {disabled: true} {|| 'ran' } } 'missing reference'
}

def "test with needs a name or a reference" []: nothing -> nothing {
  let msg: string = try { hook with {disabled: true} {|| 'ran' }; 'no error' } catch {|e| $e.msg }
  assert equal $msg 'either a name or reference is required' 'the error'
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
  assert error { hook show $.pre_prompt.9 --strict } 'strict'
}

def "test list flattens the enabled hooks" []: nothing -> nothing {
  let names: list<string> = hook list | get name
  assert equal $names ['pre_prompt[0]' named pwd display_output] 'every type, the disabled one left out'
  assert equal (hook list | where name == pwd | get ref) [$.env_change.PWD.0] 'with references'
}

def "test list by name includes disabled hooks" []: nothing -> nothing {
  assert equal (hook list off named | get name | sort) [named off] 'named hooks, disabled or not'
  assert equal (hook list nope) [] 'nothing for an unknown name'
  assert error { hook list nope --strict } 'unless --strict'
}

# ——— edit, del ————————————————————————————————————————————————————————————————

def "test edit update merges a record" []: nothing -> nothing {
  let h = hook edit $.pre_prompt.1 --update {disabled: true}
  assert equal ($h | select name disabled) {name: named disabled: true} 'returns the edited hook'
  assert not (hook is-enabled --name=named) 'and stores it'
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
  let none: string = try { hook edit $.pre_prompt.0; 'no error' } catch {|e| $e.msg }
  assert equal $none 'no overwrite value or update record was given' 'no flag'
  let missing: string = try { hook edit $.pre_prompt.9 --update {disabled: true}; 'no error' } catch {|e| $e.msg }
  assert equal $missing 'invalid hook reference: $.pre_prompt.9' 'missing reference'
  assert error { hook edit $.pre_prompt.9 --overwrite 'x' } 'overwrite needs an existing hook too'
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
  let msg: string = try { hook test $.pre_prompt.9; 'no error' } catch {|e| $e.msg }
  assert equal $msg 'no hook code exists at the provided reference' 'missing code'
  let cond: string = try { hook test $.pre_prompt.1 --condition; 'no error' } catch {|e| $e.msg }
  assert equal $cond 'no hook condition exists at the provided reference' 'missing condition'
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
