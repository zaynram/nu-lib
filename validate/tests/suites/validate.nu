# `validate rules` against small documents: `test validate/tests/suites`.
use ../mod.nu *

# A schema with every kind of rule: scalars, lists, a record, a table and its row columns.
const RULES = [
  {path: $.version type: string required: true enum: ['1.0']}
  {path: $.doc type: record required: true}
  {path: $.doc.slug type: string required: true pattern: '^[a-z]+$' help: 'lowercase letters only'}
  {path: $.doc.code type: string pattern: '^\d+$'}
  {path: $.doc.date type: 'string|datetime'}
  {path: $.doc.summary type: string max-length: 10 help: 'keep it short'}
  {path: $.doc.tags type: 'list<string>' max-items: 2 max-length: 4 enum: [a b long-tag]}
  {path: $.doc.rows type: table}
  {path: $.doc.rows.name type: string required: true}
  {path: $.doc.rows.size type: int}
  {path: $.doc.rows.marks type: 'list<string>' pattern: '^-'}
  {path: $.doc.extra type: record}
]

const GOOD = {
  version: '1.0'
  doc: {slug: abc date: 2026-01-01 summary: short tags: [a b] rows: [{name: x size: 1 marks: ['-m']} {name: y}] extra: {anything: 1}}
}

def reasons [rules: table --strict]: record -> list<string> { validate rules $rules --strict=$strict | get reason }

def "test valid" []: nothing -> nothing {
  assert equal ($GOOD | validate rules $RULES) [] 'no failures'
  assert equal ($GOOD | validate rules $RULES --strict) [] 'no failures under --strict'
  assert equal ($GOOD | validate rules $RULES | describe) 'list<any>' 'an empty table, not null'
}

def "test required and type" []: nothing -> nothing {
  assert equal ({version: '1.0'} | reasons $RULES) ['doc is missing'] 'a missing container reports once, not per child'
  let bad = $GOOD | update doc.slug 5 | update doc.date 7 | reject doc.rows
  assert equal ($bad | reasons $RULES) ['doc.slug must be string, got int' 'doc.date must be string|datetime, got int'] 'wrong types; an absent optional table is fine'
  assert equal ($GOOD | update doc.tags [1 2] | reasons $RULES) ['doc.tags must be list<string>, got list<int>'] 'element type'
  assert equal ($GOOD | update doc.tags [] | reasons $RULES) [] 'an empty list fits any list type'
  assert equal ($GOOD | update doc.extra 1 | reasons $RULES) ['doc.extra must be record, got int'] 'record'
  assert equal ($GOOD | validate rules $RULES | append ($GOOD | update version 2 | validate rules $RULES) | get rule) [type] 'rows carry the rule name'
}

def "test rows" []: nothing -> nothing {
  let bad = $GOOD | update doc.rows [{name: x} {size: big} {name: 3 marks: [m]}]
  assert equal ($bad | validate rules $RULES | select path rule) [
    {path: doc.rows.1.name rule: required}
    {path: doc.rows.2.name rule: type}
    {path: doc.rows.1.size rule: type}
    {path: doc.rows.2.marks.0 rule: pattern}
  ] 'failures name the row, in rule order'
  assert equal ($GOOD | update doc.rows nope | reasons $RULES) ['doc.rows must be table, got string'] 'a container of the wrong type reports once'
  assert equal ($GOOD | update doc.rows [] | reasons $RULES) [] 'an empty table'
}

def "test value rules" []: nothing -> nothing {
  assert equal ($GOOD | update version '2.0' | reasons $RULES) ["version must be one of 1.0, got '2.0'"] 'enum'
  assert equal ($GOOD | update doc.slug 'Ab.c' | reasons $RULES) ["doc.slug 'Ab.c' is not valid: lowercase letters only"] 'pattern with help'
  assert equal ($GOOD | insert doc.code x1 | reasons $RULES) ["doc.code 'x1' does not match ^\\d+$"] 'pattern without help'
  assert equal ($GOOD | update doc.summary 'much too long' | reasons $RULES) ['doc.summary is 13 characters, max 10: keep it short'] 'max-length'
  assert equal ($GOOD | update doc.tags [a z long-tag] | reasons $RULES) [
    'doc.tags has 3 items, max 2'
    "doc.tags.1 must be one of a, b, long-tag, got 'z'"
    'doc.tags.2 is 8 characters, max 4'
  ] 'list rules: max-items on the list, enum and max-length on each element'
}

def "test strict" []: nothing -> nothing {
  let bad = $GOOD | insert typo 1 | insert doc.slugg x | update doc.rows [{name: x colour: red} {name: y flavour: mild}]
  assert equal ($bad | reasons $RULES) [] 'unknown keys pass without --strict'
  assert equal ($bad | reasons $RULES --strict) [
    'typo is not a known key'
    'doc.slugg is not a known key'
    'doc.rows.colour is not a known key'
    'doc.rows.flavour is not a known key'
  ] 'root, record and row keys; a record with no declared children stays open'
}

def "test errors" []: nothing -> nothing {
  assert equal ($GOOD | validate rules $RULES --errors) $GOOD 'a valid record passes through'
  let raised = try { $GOOD | update version '2.0' | update doc.slug 9 | validate rules $RULES --errors | ignore; null } catch {|e| $e.msg }
  assert equal $raised "version must be one of 1.0, got '2.0'; doc.slug must be string, got int" 'every reason in one message'
}
