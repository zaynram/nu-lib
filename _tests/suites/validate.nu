# `validate string` and `validate rules` against small documents: `test _tests/suites/validate.nu`.
use validate
# the unaliased command, for the tests about colors
use validate [rules]
use ../mod.nu *

alias "validate rules" = validate rules --colors=false

# A schema with every kind of rule: scalars, lists, a record, a table and its row columns.
const RULES = [
  {path: $.version type: string required: true enum: ['1.0']}
  {path: $.doc type: record required: true}
  {path: $.doc.slug type: string required: true pattern: '^[a-z]+$' class: 'lowercase letters only'}
  {path: $.doc.code type: string pattern: '^\d+$'}
  {path: $.doc.date type: 'string|datetime'}
  {path: $.doc.summary type: string max-length: 10}
  {path: $.doc.tags type: 'list<string>' max-items: 2 max-length: 4 enum: [a b long-tag]}
  {path: $.doc.rows type: table}
  {path: $.doc.rows.name type: string required: true}
  {path: $.doc.rows.size type: int}
  {path: $.doc.rows.marks type: 'list<string>' pattern: '^-'}
  {path: $.doc.flag type: 'string|bool' max-length: 3 pattern: '^o'}
  {path: $.doc.extra type: record}
]

const GOOD = {
  version: '1.0'
  doc: {
    slug: abc
    date: 2026-01-01
    summary: short
    tags: [a b]
    rows: [{name: x size: 1 marks: ['-m']} {name: y}]
    extra: {anything: 1}
  }
}

def hints [rules: table = $RULES --strict]: record -> list<string> {
  validate rules $rules --strict=$strict | get $.hint? | default []
}

def "test basic-validation" []: nothing -> nothing {
  assert equal ($GOOD | validate rules $RULES) $GOOD 'validation succeeds with good data (and returns data by default)'
  assert equal ($GOOD | validate rules --strict $RULES) $GOOD 'validation succeeds with good data and `--strict`'
  assert equal ($GOOD | validate rules --return=input $RULES) $GOOD 'successful validation with `--return=input` returns the input data'
  assert equal ($GOOD | validate rules --return=table $RULES) [] 'successful validation with `--return=table` returns an empty list'
  assert equal ($GOOD | validate rules --return=nothing $RULES) null 'successful validation with `--return=nothing` returns `null`'
}

def "test mandatory-rule-evaluation" []: nothing -> nothing {
  let hints: list = {version: '1.0'} | hints
  assert length $hints 1 'missing containers report a single time'
  assert str contains $hints.0? '$.doc must be a non-null value' 'missing container reports unsatisfied requirement'
}

def "test typecheck-rule-evaluation" []: nothing -> nothing {
  let hints: list = $GOOD | update doc.slug 5 | update doc.date 7 | reject doc.rows | hints
  assert length $hints 2 'type mismatches are reported'
  assert compare {|a b|
    $a | zip $b | all {|x| $x.0 =~ $x.1 }
  } $hints [
    'has type int; expected string'
    'has type int; expected string|datetime'
  ] 'simple type mismatches are reported in order'
  let hints: list = $GOOD | update doc.tags [1.2] | hints
  assert greater ($hints | length) 0 'element type mismatches are detected'
  assert str contains $hints.0? 'has type list<float>; expected list<string>' 'element type mismatches are reported properly'
  assert length ($GOOD | update doc.tags [] | hints) 0 'an empty list fits any list type'
  let hints: list = $GOOD | update doc.extra 1 | hints
  assert greater ($hints | length) 0 'container type mismatches are detected'
  assert str contains $hints.0? 'has type int; expected record' 'container type mismatches are reported'
  let rules: list = ($GOOD | update version 2 | validate rules $RULES).rule?
  assert greater ($rules | length) 0 'rows with type mismatches have rule names'
  assert equal $rules.0? typecheck 'rows with type mismatches report the correct rule name'
}

def "test table-row-rule-evaluation" []: nothing -> nothing {
  let bad = $GOOD | update doc.rows [{name: x} {size: big} {name: 3 marks: [m]}]
  assert equal ($bad | validate rules $RULES | select path rule) [
    [path rule];
    [$.doc.rows.1.name mandatory]
    [$.doc.rows.2.name typecheck]
    [$.doc.rows.1.size typecheck]
    [$.doc.rows.2.marks.0 regex-simple]
  ] 'validation errors in table rows name the row, in rule order'
  assert length ($GOOD | update doc.rows nope | hints) 1 'a container of the wrong type reports once'
  assert equal ($GOOD | update doc.rows [] | hints) [] 'table with no rows does not report errors'
}

def "test value-rule-evaluation" []: nothing -> nothing {
  assert equal ($GOOD | update version '2.0' | hints) ["$.version is `2.0`, which is not one of [1.0]"] 'enumerable rule'
  assert equal ($GOOD | update doc.slug 'Ab.c' | hints) ["$.doc.slug is 'Ab.c'; expected lowercase letters only ('^[a-z]+$')"] 'regex-class rule'
  assert equal ($GOOD | insert doc.code x1 | hints) ["$.doc.code is 'x1' which does not match '^\\d+$'"] 'regex-simple rule'
  assert equal ($GOOD | update doc.summary 'much too long' | hints) ['$.doc.summary is 13 characters (max: 10)'] 'max-length rule'
  assert equal ($GOOD | update doc.tags [a z long-tag] | hints) [
    '$.doc.tags has 3 items (max: 2)'
    "$.doc.tags.1 is `z`, which is not one of [a, b, long-tag]"
    '$.doc.tags.2 is 8 characters (max: 4)'
  ] 'list rules: max-items on the list, enum and max-length on each element'
}

def "test union-type-rule-evaluation" []: nothing -> nothing {
  assert length ($GOOD | insert doc.flag true | hints) 0 'string rules skip judgement on non-strings'
  let hints: list = $GOOD | insert doc.flag nope | hints
  assert compare {|a b|
    $a | zip $b | all ($it.0? =~ $it.1?)
  } $hints [
    "4 characters \\(max: 3\\)"
    "is 'nope' which does not match '\\^o'"
  ] 'string rules judge strings'
}

def "test validation-with-strict" []: nothing -> nothing {
  let data: record = $GOOD | insert typo 1 | insert doc.slugg x | update doc.rows [{name: x colour: red} {name: y flavour: mild}]
  assert equal ($data | hints) [] 'foreign keys pass without --strict'
  let found = $data | validate rules $RULES --strict
  assert equal ($found | get path) [$.typo $.doc.slugg $.doc.rows.0.colour $.doc.rows.1.flavour] 'undeclared keys are reported per container, in rule order, table rows by index; a record with no declared children (extra) stays open'
  assert equal ($found | get rule | uniq) [foreign-key] 'undeclared keys are foreign-key failures'
  assert equal $found.0?.hint 'ensure $.typo is a valid property' 'the foreign-key hint names the key'
  assert equal ($GOOD | update doc 7 | hints --strict) ['$.doc has type int; expected record'] 'containers under a failed container are not scanned'
}

def "test return-one-bails-on-the-first-failure" []: nothing -> nothing {
  let bad = $GOOD | update version '2.0' | update doc.rows [{name: x} {size: big}]
  assert equal ($bad | validate rules $RULES --return=one | select path rule) {path: $.version rule: enumerable} 'the first failing rule is returned as a record'
  assert equal ($GOOD | update doc.rows nope | validate rules $RULES --return=one | select path rule) {path: $.doc.rows rule: typecheck} 'a mistyped table reports itself, not its rows'
  assert equal ($GOOD | update doc.rows [{name: x} {size: big}] | validate rules $RULES --return=one | select path rule) {path: $.doc.rows.1.name rule: mandatory} 'table rows are judged in order'
  assert equal ($GOOD | validate rules $RULES --return=one) null 'valid data returns null'
  assert equal ($GOOD | insert typo 1 | validate rules $RULES --return=one --strict | select path rule) {path: $.typo rule: foreign-key} 'strict mode bails on the first undeclared key'
  assert equal ($GOOD | insert doc.rows.0.colour red | validate rules $RULES --return=one --strict | select path rule) {path: $.doc.rows.0.colour rule: foreign-key} 'strict mode scans table rows, naming the row'
}

def "test validation-with-errors" []: nothing -> nothing {
  assert equal ($GOOD | validate rules $RULES --errors) $GOOD 'a valid record passes through'
  let raised = try { $GOOD | update version '2.0' | update doc.slug 9 | validate rules --errors $RULES --errors | ignore; null } catch {|e| $e.details.help }
  assert str contains $raised "version is `2.0`, which is not one of [1.0]" 'first reason in help text'
  assert str contains $raised "doc.slug has type int; expected string" 'second reason in help text'
}

# Dynamic rules: a named closure per path, run on scalars and once per element of a list or table.
const DYNAMIC_DOC = {
  tasks: [
    {id: a labels: [':current'] issue: {state: OPEN status: Pending}}
    {id: b labels: [] issue: null}
    {id: c labels: [':ready'] issue: {state: CLOSED status: Complete}}
  ]
  count: 7
}

def "test dynamic-rule-runs-alone" []: nothing -> nothing {
  let rules = [{path: $.count type: int dynamic: {even: {|v at| if $v mod 2 != 0 { error make --unspanned {msg: 'value is odd' help: $'($at) must be even'} } }}}]
  let found = $DYNAMIC_DOC | validate rules $rules
  assert length $found 1 'a rule with only `dynamic` is evaluated'
  assert equal ($found.0? | select path rule reason hint data) {path: $.count rule: even reason: 'value is odd' hint: '$.count must be even' data: null} 'a raised error maps msg to reason and help to hint, with no data'
  assert equal ($DYNAMIC_DOC | update count 8 | validate rules $rules) ($DYNAMIC_DOC | update count 8) 'a passing dynamic rule returns the input'
}

def "test dynamic-rule-per-row" []: nothing -> nothing {
  let rules = [
    {path: $.tasks type: table}
    {path: $.tasks type: table dynamic: {focus-on-blocked: {|row at|
      if ($row.labels has ':current' or $row.labels has ':ready') and $row.issue?.status? == Pending {
        {reason: 'focus on blocked work' hint: $'($row.id) is Pending' task_id: $row.id fix: 'todoist.unlabel=:current'}
      }
    }}}
  ]
  let found = $DYNAMIC_DOC | validate rules $rules
  assert length $found 1 'the closure runs once per row and reports only the rows that fail'
  assert equal $found.0?.path $.tasks.0 'the failure path names the row'
  assert equal $found.0?.rule focus-on-blocked 'the record key is the rule name'
  assert equal $found.0?.hint 'a is Pending' 'a returned record maps hint'
  assert equal $found.0?.data {task_id: a fix: 'todoist.unlabel=:current'} 'every other field of a returned record is kept as data'
}

def "test dynamic-rule-templates-see-data" []: nothing -> nothing {
  let rules = [{path: $.tasks type: table dynamic: {closed: {|row at|
    if $row.issue?.state? == CLOSED { {reason: 'pointer open, issue closed' hint: '{at}: complete {task_id}' task_id: $row.id} }
  }}}]
  let found = $DYNAMIC_DOC | validate rules $rules --colors=false
  assert length $found 1 'one closed issue'
  assert equal $found.0?.hint '$.tasks.2: complete c' 'templates are filled from the path and the returned data'
  assert equal ($found | get rule) [closed] 'rule names are kept'
}

def "test table-row-rules-return-structured-rows" []: nothing -> nothing {
  let found = $GOOD | update doc.rows [{name: x} {size: big}] | validate rules $RULES
  assert equal ($found | columns) [path rule hint reason data] 'every failure row has the same columns, data included'
  assert ($found | all {|r| $r.data == null }) 'preset rules carry no data'
}

# ——— validate string ——————————————————————————————————————————————————————————

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

def "test string examples" []: nothing -> nothing {
  assert equal (do ('abc' | validate string \w+)) abc 'a matching string is returned by the closure'
  assert equal (do ('x' | validate string --enum=[x y z])) x 'an enum member is returned'
  assert equal (do ('nan' | validate string --not '\d+')) 'nan' 'a string not matching a negated pattern is returned'
}

def "test string returns a closure either way" []: nothing -> nothing {
  assert equal ('abc' | validate string 'b' | describe) closure 'a pass returns a closure'
  assert equal ('abc' | validate string 'z' | describe) closure 'a failure returns a closure instead of raising'
}

def "test string regex is unanchored" []: nothing -> nothing {
  assert equal (do ('abc!' | validate string '\w+')) 'abc!' 'a partial match passes'
  assert ((caught { do ('abc!' | validate string '^\w+$') }) != null) 'anchors make it strict'
}

def "test string failure details" []: nothing -> nothing {
  let e = caught { do ('x!' | validate string '^\w+$') }
  assert equal $e.msg 'the provided string is invalid' 'default message'
  assert equal $e.code 'internal::validate::string_unmatched_regex' 'default code'
  assert equal ($e.labels | get text) [string regex] 'the input and the regex are labelled'
  assert equal $e.help null 'no help without --instruct'
  assert equal $e.inner [] 'no inner errors by default'
}

def "test string enum failure labels the enum" []: nothing -> nothing {
  let e = caught { do ('q' | validate string --enum [a b]) }
  assert equal ($e.labels | get text) [string enum] 'the input and the enum are labelled'
}

def "test string passes with either regex or enum" []: nothing -> nothing {
  assert equal (do ('b' | validate string '^a' --enum [b])) b 'an enum member passes a failing regex'
  assert equal (do ('ab' | validate string '^a' --enum [b])) ab 'a regex match passes outside the enum'
}

def "test string not inverts regex and enum" []: nothing -> nothing {
  assert ((caught { do ('123' | validate string --not '\d+') }) != null) 'a match fails under --not'
  assert ((caught { do ('a' | validate string --not --enum [a b]) }) != null) 'a member fails under --not'
  assert equal (do ('c' | validate string --not --enum [a b])) c 'a non-member passes under --not'
}

def "test string without regex or enum" []: nothing -> nothing {
  assert ((caught { do ('anything' | validate string) }) != null) 'every string fails'
  assert equal (do ('anything' | validate string --not)) anything 'every string passes under --not'
}

def "test string custom error fields" []: nothing -> nothing {
  let e = caught { do ('q' | validate string a --message 'bad q' --code 'my::code' --instruct 'use a' --inner [{msg: 'why'}]) }
  assert equal $e.msg 'bad q' '--message'
  assert equal $e.code 'my::code' '--code'
  assert equal $e.help 'use a' '--instruct is the help'
  assert equal ($e.inner | get msg) [why] '--inner'
}

def "test string custom labels replace the defaults" []: nothing -> nothing {
  let span = (metadata 'q').span
  let e = caught { do ('q' | validate string a --labels [{text: 'right here' span: $span}]) }
  assert equal ($e.labels | get text) ['right here'] 'only the given labels'
}

# ——— validate rules: types ————————————————————————————————————————————————————

def "test rules examples" []: nothing -> nothing {
  assert equal ({name: 5} | rules [{path: $.name type: string required: true} {path: $.size type: int required: true}] --colors=false | get hint) ['$.name has type int; expected string' '$.size must be a non-null value'] 'every failure as a row'
  assert equal ({name: a} | rules [{path: $.name type: string}] --errors) {name: a} 'a guard in a pipeline'
}

def "test a rule without a type accepts any value" []: nothing -> nothing {
  assert equal ({a: 1} | validate rules [{path: $.a required: true}]) {a: 1} 'the type defaults to any'
  assert equal ({b: 1} | validate rules [{path: $.a required: true}] | get hint) ['$.a must be a non-null value'] 'the requirement still applies'
  assert equal ({a: [1 x]} | validate rules [{path: $.a enum: [1 x]}]) {a: [1 x]} 'other rules still apply'
}

def "test type any accepts every value" []: nothing -> nothing {
  let doc = {a: 1 b: x c: [1] d: {e: 1} f: null g: 2026-01-01}
  let rules = [a b c d f g] | each {|k| {path: ([$k] | into cell-path) type: any} }
  assert equal ($doc | validate rules $rules) $doc 'nothing fails'
  assert equal ({a: [1 x]} | validate rules [{path: $.a type: 'list<any>'}]) {a: [1 x]} 'list<any> accepts mixed lists'
}

def "test type number accepts ints and floats" []: nothing -> nothing {
  assert equal ({a: 1 b: 1.5} | validate rules [{path: $.a type: number} {path: $.b type: number}]) {a: 1 b: 1.5} 'int and float'
  assert equal ({a: '1'} | validate rules [{path: $.a type: number}] | get hint) ['$.a has type string; expected number'] 'a string is not a number'
  assert equal ({a: [1 2.5]} | validate rules [{path: $.a type: 'list<number>'}]) {a: [1 2.5]} 'inside a list'
}

def "test union types split only at the top level" []: nothing -> nothing {
  assert equal ({a: [1 b]} | validate rules [{path: $.a type: 'list<int|string>'}]) {a: [1 b]} 'a union inside a generic'
  assert equal ({a: [1.5]} | validate rules [{path: $.a type: 'list<int|string>'}] | get hint) ['$.a has type list<float>; expected list<int|string>'] 'elements outside the inner union fail'
  assert equal ({a: x} | validate rules [{path: $.a type: 'list<int|string>|string'}]) {a: x} 'a top-level alternative after a generic'
  assert equal ({a: [x]} | validate rules [{path: $.a type: 'string|list<int|string>'}]) {a: [x]} 'a generic alternative after a scalar'
}

def "test nested generic types" []: nothing -> nothing {
  assert equal ({a: [[1] [2 3]]} | validate rules [{path: $.a type: 'list<list<int>>'}]) {a: [[1] [2 3]]} 'list of lists'
  assert equal ({a: [[1] [x]]} | validate rules [{path: $.a type: 'list<list<int>>'}] | get rule) [typecheck] 'an inner mismatch fails'
}

def "test an empty list fits only list types" []: nothing -> nothing {
  assert equal ({a: []} | validate rules [{path: $.a type: int}] | get hint) ['$.a has type list<any>; expected int'] 'an empty list is not an int'
  assert equal ({a: []} | validate rules [{path: $.a type: table}]) {a: []} 'an empty list is an empty table'
}

def "test table type accepts a list of records only" []: nothing -> nothing {
  assert equal ({t: [{a: 1} {b: 2}]} | validate rules [{path: $.t type: table}]) {t: [{a: 1} {b: 2}]} 'records with different keys'
  assert equal ({t: [1 2]} | validate rules [{path: $.t type: table}] | get rule) [typecheck] 'a list of ints is not a table'
  assert equal ({t: [{a: 1}]} | validate rules [{path: $.t type: string}] | get rule) [typecheck] 'a table is not a string'
}

def "test record type" []: nothing -> nothing {
  assert equal ({r: {x: 1}} | validate rules [{path: $.r type: record}]) {r: {x: 1}} 'a record'
  assert equal ({r: [{x: 1}]} | validate rules [{path: $.r type: record}] | get rule) [typecheck] 'a table is not a record'
}

# ——— validate rules: list<record> tables ——————————————————————————————————————

def "test list of records rules judge every row" []: nothing -> nothing {
  let rules = [{path: $.t type: 'list<record>'} {path: $.t.n type: string required: true}]
  assert equal ({t: [{n: a} {n: 1} {}]} | validate rules $rules | select path rule) [
    [path rule];
    [$.t.1.n typecheck]
    [$.t.2.n mandatory]
  ] 'rows are named like a table'
  assert equal ({t: [{n: a}]} | validate rules $rules --return=one) null 'valid rows pass'
}

def "test strict scans list of records rows" []: nothing -> nothing {
  let rules = [{path: $.t type: 'list<record>'} {path: $.t.n type: string}]
  assert equal ({t: [{n: a z: 1}]} | validate rules $rules --strict | get path) [$.t.0.z] 'undeclared row keys are reported'
}

# ——— validate rules: value rules ——————————————————————————————————————————————

def "test min length" []: nothing -> nothing {
  let rules = [{path: $.s type: string min-length: 3} {path: $.l type: 'list<string>' min-length: 2}]
  assert equal ({s: abc l: [ab]} | validate rules $rules) {s: abc l: [ab]} 'long enough'
  assert equal ({s: ab l: [ab c]} | validate rules $rules | get hint) ['$.s is 2 characters (min: 3)' '$.l.1 is 1 characters (min: 2)'] 'too short, also per element'
}

def "test min items" []: nothing -> nothing {
  let rules = [{path: $.l type: 'list<int>' min-items: 2} {path: $.t type: table min-items: 1}]
  assert equal ({l: [1 2] t: [{a: 1}]} | validate rules $rules) {l: [1 2] t: [{a: 1}]} 'enough items'
  assert equal ({l: [1] t: []} | validate rules $rules | get hint) ['$.l has 1 items (min: 2)' '$.t has 0 items (min: 1)'] 'too few items'
}

def "test const on a scalar" []: nothing -> nothing {
  assert equal ({a: 4} | validate rules [{path: $.a const: 4}]) {a: 4} 'equal'
  assert equal ({a: 5} | validate rules [{path: $.a const: 4}] | select rule hint) [[rule hint]; [any-const '$.a must be exactly 4']] 'a non-string constant'
  assert equal ({a: y} | validate rules [{path: $.a const: x}] | select rule hint) [[rule hint]; [str-const "$.a must be exactly 'x'"]] 'a string constant is quoted'
}

def "test const on a list compares elements to a scalar constant" []: nothing -> nothing {
  assert equal ({a: [1 1]} | validate rules [{path: $.a const: 1}]) {a: [1 1]} 'every element equals the constant'
  assert equal ({a: [1 2]} | validate rules [{path: $.a const: 1}] | get path) [$.a.1] 'the element that differs'
}

def "test const with a list constant compares the whole value" []: nothing -> nothing {
  assert equal ({a: [1 2]} | validate rules [{path: $.a const: [1 2]}]) {a: [1 2]} 'an equal list passes'
  assert equal ({a: [2 1]} | validate rules [{path: $.a const: [1 2]}] | select path hint) [[path hint]; [$.a '$.a must be exactly [1, 2]']] 'one failure for the list'
  assert equal ({a: x} | validate rules [{path: $.a const: [x]}] | get path) [$.a] 'a scalar never equals a list'
}

def "test const ignores an absent optional value" []: nothing -> nothing {
  assert equal ({} | validate rules [{path: $.a const: 1}]) {} 'nothing to compare'
}

def "test enum on a scalar" []: nothing -> nothing {
  assert equal ({a: 3} | validate rules [{path: $.a type: int enum: [1 2]}] | get hint) ['$.a is `3`, which is not one of [1, 2]'] 'a non-member'
  assert equal ({a: 2} | validate rules [{path: $.a type: int enum: [1 2]}]) {a: 2} 'a member'
}

def "test null list elements" []: nothing -> nothing {
  assert equal ({l: [a null]} | validate rules [{path: $.l type: 'list<any>' required: true enum: [a]}] | select path rule) [[path rule]; [$.l.1 mandatory]] 'a required list has no null elements'
  assert equal ({l: [3 null]} | validate rules [{path: $.l type: 'list<any>' enum: [3]}]) {l: [3 null]} 'null elements of an optional list are skipped'
}

# ——— validate rules: return modes and colors —————————————————————————————————

def "test return rejects unknown values" []: nothing -> nothing {
  let e = caught { {a: 1} | validate rules [{path: $.a type: int}] --return=bogus }
  assert equal $e.msg "invalid --return value 'bogus'" 'the value is named'
  assert equal $e.code 'validate::rules::invalid_return' 'a stable code'
  assert str contains ($e.labels.0?.text? | default '') 'one, input, nothing, table' 'the label lists the valid values'
  assert ((caught { {a: x} | validate rules [{path: $.a type: int}] --return=bogus }) != null) 'also when validation fails'
}

def "test return one honours colors" []: nothing -> nothing {
  let rule = [{path: $.a type: int}]
  let plain = {a: x} | rules $rule --return=one --colors=false
  assert equal $plain.hint '$.a has type string; expected int' 'no styles with --colors=false'
  let styled = {a: x} | rules $rule --return=one
  assert ($styled.hint != ($styled.hint | ansi strip)) 'styled by default'
  assert equal ($styled.hint | ansi strip) $plain.hint 'the same text'
  let strict = {a: 1 b: 2} | rules $rule --return=one --strict --colors=false
  assert equal $strict.hint 'ensure $.b is a valid property' 'foreign keys too'
}

def "test colors style hints by default" []: nothing -> nothing {
  let rule = [{path: $.a type: int}]
  let styled = {a: x} | rules $rule | get hint.0
  assert ($styled =~ '\e\[') 'the hint has ANSI codes'
  assert equal ($styled | ansi strip) ({a: x} | rules $rule --colors=false | get hint.0) 'stripping matches --colors=false'
}

def "test errors help lines are aligned" []: nothing -> nothing {
  let rules = 0..10 | each {|i| {path: ([$"k($i)"] | into cell-path) required: true} }
  let help = (caught { {} | validate rules $rules --errors }).help | lines
  assert equal ($help | length) 11 'one line per failure'
  assert equal ($help | each { str index-of ':' } | uniq | length) 1 'the colons line up'
  assert ($help.0? | default '' | str starts-with '[0] : ') 'single-digit indexes are padded'
  assert equal (caught { {} | validate rules $rules --errors }).code 'validate::rules::validation_failed' 'a stable code'
}

def "test return one overrides errors" []: nothing -> nothing {
  assert equal ({a: x} | validate rules [{path: $.a type: int}] --return=one --errors | get rule) typecheck 'the failure is returned, not raised'
}

def "test failures are returned regardless of return mode" []: nothing -> nothing {
  for mode in [input nothing table] {
    assert equal ({a: x} | validate rules [{path: $.a type: int}] --return=$mode | get rule) [typecheck] $'--return=($mode) still returns failures'
  }
}

# ——— validate rules: strict ———————————————————————————————————————————————————

def "test strict reports every row with an undeclared key" []: nothing -> nothing {
  let rules = [{path: $.t type: table} {path: $.t.n type: int}]
  assert equal ({t: [{n: 1 x: 1} {n: 2 x: 2}]} | validate rules $rules --strict | get path) [$.t.0.x $.t.1.x] 'one failure per row'
}

def "test strict names the row of a record under a table" []: nothing -> nothing {
  let rules = [{path: $.t type: table} {path: $.t.r type: record} {path: $.t.r.q type: int}]
  let doc = {t: [{r: {q: 1}} {r: {q: 2 z: 3}}]}
  assert equal ($doc | validate rules $rules --strict | get path) [$.t.1.r.z] 'all non-strict failures'
  assert equal ($doc | validate rules $rules --strict --return=one | get path) $.t.1.r.z 'the first failure'
}

def "test children of a mistyped record in a table row are not judged" []: nothing -> nothing {
  let rules = [{path: $.t type: table} {path: $.t.r type: record} {path: $.t.r.q type: int required: true}]
  assert equal ({t: [{r: 5} {r: {}}]} | validate rules $rules | select path rule) [
    [path rule];
    [$.t.0.r typecheck]
    [$.t.1.r.q mandatory]
  ] 'the container reports; its children are judged only where it is a record'
  assert equal ({t: [{r: 5}]} | validate rules $rules --return=one | get path) $.t.0.r 'the same when bailing'
}

def "test return one skips the children of an absent container" []: nothing -> nothing {
  let rules = [{path: $.r type: record} {path: $.r.q type: int required: true}]
  assert equal ({} | validate rules $rules --return=one) null 'the same verdict as without --return=one'
  assert equal ({} | validate rules $rules) {} 'which passes'
  assert equal ({r: {}} | validate rules $rules --return=one | get path) $.r.q 'a present container is judged'
}

def "test children of an absent record in a table row are not judged" []: nothing -> nothing {
  let rules = [{path: $.t type: table} {path: $.t.r type: record} {path: $.t.r.q type: int required: true}]
  assert equal ({t: [{} {r: {}}]} | validate rules $rules | get path) [$.t.1.r.q] 'only the row whose container is present'
  assert equal ({t: [{} {r: {}}]} | validate rules $rules --return=one | get path) $.t.1.r.q 'the same when bailing'
}

def "test a path through a scalar does not crash" []: nothing -> nothing {
  let rules = [{path: $.r.q type: int required: true}]
  assert ((caught { {r: 5} | validate rules $rules }) == null) 'a scalar where a record is expected'
  assert ((caught { {r: [1 2]} | validate rules $rules }) == null) 'a list of scalars where a record is expected'
  assert ((caught { {r: 5} | validate rules $rules --return=one --strict }) == null) 'also when bailing'
}

# ignore: pending decision V13 (a key under an undeclared, mistyped container is not judged, even when required)
def "test a key under an undeclared mistyped container is not judged" []: nothing -> nothing {
  assert equal ({r: 5} | validate rules [{path: $.r.q type: int required: true}]) {r: 5} 'no failure without a rule for the container'
}

def "test strict skips a mistyped record under a table" []: nothing -> nothing {
  let rules = [{path: $.t type: table} {path: $.t.r type: record} {path: $.t.r.q type: int}]
  assert equal ({t: [{r: 5}]} | validate rules $rules --strict | get path) [$.t.0.r] 'only the typecheck is reported'
}

def "test strict on an open root" []: nothing -> nothing {
  assert equal ({a: {b: 1}} | validate rules [{path: $.a type: record}] --strict) {a: {b: 1}} 'a record without child rules is open'
}

# ——— validate rules: dynamic ——————————————————————————————————————————————————

def "test dynamic rule text keeps unknown braces" []: nothing -> nothing {
  let rules = [{path: $.a type: int dynamic: {x: {|v| {reason: 'use {braces} here' hint: '{at} wants {nope} and {}' extra: 1} }}}]
  let found = {a: 1} | validate rules $rules
  assert equal $found.0?.reason? 'use {braces} here' 'an unknown placeholder stays literal'
  assert equal $found.0?.hint? '$.a wants {nope} and {}' 'known placeholders are filled, others kept'
}

def "test dynamic rule raised text keeps unknown braces" []: nothing -> nothing {
  let rules = [{path: $.a type: int dynamic: {x: {|v| error make --unspanned {msg: 'a {literal} reason' help: '{at}: {x'} }}}]
  let found = {a: 1} | validate rules $rules
  assert equal [$found.0?.reason? $found.0?.hint?] ['a {literal} reason' '$.a: {x'] 'raised text is filled the same way'
}

def "test dynamic rule data fields fill templates" []: nothing -> nothing {
  let rules = [{path: $.a type: int dynamic: {x: {|v| {reason: 'r' hint: '{n} is {kind}' n: $v kind: odd} }}}]
  assert equal ({a: 3} | validate rules $rules | get hint) ['3 is odd'] 'data fields are placeholders'
}

def "test dynamic rule runs every named closure" []: nothing -> nothing {
  let rules = [{path: $.a type: int dynamic: {
    positive: {|v| if $v <= 0 { {reason: 'not positive'} } }
    even: {|v| if $v mod 2 != 0 { {reason: 'odd'} } }
    small: {|v| if $v > 100 { {reason: 'big'} } }
  }}]
  assert equal ({a: -3} | validate rules $rules | select rule reason) [[rule reason]; [positive 'not positive'] [even odd]] 'every failing closure reports, in order'
  assert equal ({a: -3} | validate rules $rules --return=one | get rule) positive 'the first one bails'
  assert equal ({a: 2} | validate rules $rules) {a: 2} 'all pass'
}

def "test dynamic rule receives value and path" []: nothing -> nothing {
  let rules = [{path: $.l type: 'list<int>' dynamic: {seen: {|v at| {reason: $'($in) ($v) ($at)'} }}}]
  assert equal ({l: [5]} | validate rules $rules | get reason) ['5 5 $.l.0'] 'input, first positional and path'
}

def "test dynamic rule non record results pass" []: nothing -> nothing {
  let rules = [{path: $.a type: int dynamic: {x: {|v| 'not a failure' }}} {path: $.b type: int dynamic: {y: {|v| {other: 1} }}}]
  assert equal ({a: 1 b: 2} | validate rules $rules) {a: 1 b: 2} 'strings and records without reason pass'
}

def "test dynamic rule msg and help aliases" []: nothing -> nothing {
  let rules = [{path: $.a type: int dynamic: {x: {|v| {msg: 'm' help: 'h'} }}}]
  assert equal ({a: 1} | validate rules $rules | select reason hint data) [[reason hint data]; [m h null]] 'msg/help work like reason/hint'
  let rules = [{path: $.a type: int dynamic: {x: {|v| {reason: 'only reason'} }}}]
  assert equal ({a: 1} | validate rules $rules | get hint) ['only reason'] 'the hint defaults to the reason'
}
