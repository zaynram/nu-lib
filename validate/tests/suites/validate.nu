# `validate rules` against small documents: `test validate/tests/suites`.
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
  assert compare {|a b| $a | zip $b | all ($'($it | first)' =~ $'ensure ($it | last) is spelled correctly') } ($data | hints --strict) [
    typo
    doc.slugg
    doc.rows.colour
    doc.rows.flavour
  ] 'record with no declared children stays open'
  assert equal ($GOOD | update doc 7 | hints --strict) ['$.doc has type int; expected record'] 'containers under a failed container are not scanned'
}

def "test validation-with-errors" []: nothing -> nothing {
  assert equal ($GOOD | validate rules $RULES --errors) $GOOD 'a valid record passes through'
  let raised = try { $GOOD | update version '2.0' | update doc.slug 9 | validate rules --errors $RULES --errors | ignore; null } catch {|e| $e.details.help }
  assert str contains $raised "version is `2.0`, which is not one of [1.0]" 'first reason in help text'
  assert str contains $raised "doc.slug has type int; expected string" 'second reason in help text'
}
