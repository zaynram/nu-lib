# Suite of validation tools to assist with custom command definitions and parameter validation.

# `validate string` returns a closure intentionally (its labels carry spans, which only mean something in the caller's scope):
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.
# - Returning raw details records would require each consumer to typecheck the return value
# - Closure values allow for ergonomic usage - `... | validate string <regex> | do $in`
# - Validation error reporting can be handled in a single line, with re-assignment support for valid items.
#
# `validate rules` returns its failures as data instead: its messages name the path themselves, so no span is needed,
# and callers reword them. `--errors` raises them for callers that only want a guard.

# Validate a string using pattern matching with regular expressions.
@category test
@example 'validate a string matches a regex pattern' { do ('abc' | validate string \w+) } --result=abc
@example 'validate a string is an enum member' { do ('x' | validate string --enum=[x y z]) } --result=x
@example 'validate a string does not match a pattern' { do ('nan' | validate string --not '\d+') } --result='nan'
export def string [
  regex?: string
  # Regex expression to validate the string with (`$in =~ $regex`)
  --not (-n)
  # Invert the validation behavior (`$in !~ $regex`; `$enum not-has $in`)
  --enum: list<string> = []
  # List of valid values to test for membership with the input value (`$enum has $in`)
  --message: string = 'the provided string is invalid'
  # Error message for validation failures
  --code: string = 'internal::validate::string_unmatched_regex'
  # Error code for validation failures
  --labels: table<text: string, span: record> = []
  # Error labels for validation errors; the input and regex pattern will be included if this is empty
  --inner: list<record> = []
  # Inner error(s) to include in the error details for validation errors
  --help: string
  # Requirement description or other helpful information for additional context
]: string -> closure {
  if (($regex != null and $in =~ $regex) or $enum has $in) != $not { let s: string; {|| $s } } else {
    let value: record = metadata | {text: string span: $in.span}
    let check: record = if $regex != null { {text: regex span: (metadata $regex).span} } else { {text: enum span: (metadata $enum).span} }
    let labels: table<text: string, span: record> = $labels | default --empty [$value $check]
    {|| error make ({msg: $message code: $code labels: $labels inner: $inner help: $help} | compact --empty) }
  }
}

# Does `value` have `type`: a `describe` name, `record`, `table`, `list<inner>`, or alternatives joined by `|`.
def fits [value: any type: string]: nothing -> bool {
  let kind: string = $value | describe
  if $kind == $type { return true }
  for t in ($type | split row '|') {
    let ok: bool = if $t == record {
      $kind starts-with record
    } else if $t == table {
      ($kind starts-with table) or (($kind starts-with list) and ($value | all {|e| ($e | describe) starts-with record }))
    } else if ($t starts-with 'list<') {
      ($kind =~ '^(list|table)') and ($value | all {|e| fits $e ($t | str substring 5..-2) })
    } else { $kind == $t }
    if $ok { return true }
  }
  false
}

# The failures of one rule at one place. `enum`, `pattern` and `max-length` judge each element of a list.
def verdicts [rule: record at: string value: any]: nothing -> list<record> {
  if $value == null {
    return (if ($rule.required? | default false) { [{path: $at rule: required reason: $"($at) is missing"}] } else { [] })
  }
  if not (fits $value $rule.type) {
    return [{path: $at rule: type reason: $"($at) must be ($rule.type), got ($value | describe)"}]
  }
  let listed: bool = ($value | describe) =~ '^(list|table)'
  mut found: list<record> = []
  if $listed and $rule.max-items? != null and ($value | length) > $rule.max-items {
    $found ++= [{path: $at rule: max-items reason: $"($at) has ($value | length) items, max ($rule.max-items)"}]
  }
  if $rule.enum? == null and $rule.pattern? == null and $rule.max-length? == null { return $found }
  let help: string = if $rule.help? == null { '' } else { $": ($rule.help)" }
  let places: list<record> = if $listed { $value | enumerate | each {|e| {at: $"($at).($e.index)" value: $e.item} } } else { [{at: $at value: $value}] }
  for p in $places {
    # `pattern` and `max-length` judge strings only, so a `string|bool` key can carry them.
    let text: bool = ($p.value | describe) == string
    if $rule.enum? != null and $p.value not-in $rule.enum {
      $found ++= [{path: $p.at rule: enum reason: $"($p.at) must be one of ($rule.enum | str join ', '), got '($p.value)'($help)"}]
    } else if $rule.pattern? != null and $text and $p.value !~ $rule.pattern {
      let why: string = if $rule.help? == null { $"does not match ($rule.pattern)" } else { $"is not valid($help)" }
      $found ++= [{path: $p.at rule: pattern reason: $"($p.at) '($p.value)' ($why)"}]
    } else if $rule.max-length? != null and $text and ($p.value | str length) > $rule.max-length {
      $found ++= [{path: $p.at rule: max-length reason: $"($p.at) is ($p.value | str length) characters, max ($rule.max-length)($help)"}]
    }
  }
  $found
}

# Validate a record against a table of rules; returns one row per failure, empty when the record is valid.
#
# A rule row has `path` (a cell path such as `$.ticket.slug`) and `type`, then optionally `required`, `enum`,
# `pattern`, `max-length`, `max-items` and `help`. A path through a `table` rule is judged on every row of
# that table. Rules for a container come before the rules for its children; the children of an absent or
# failed container are not judged.
@category test
@example 'every failure as a row' {
  {name: 5} | validate rules [{path: $.name type: string required: true} {path: $.size type: int required: true}] | get reason
} --result ['name must be string, got int' 'size is missing']
@example 'a guard in a pipeline' { {name: a} | validate rules [{path: $.name type: string}] --errors } --result {name: a}
export def rules [
  rules: table
  # One row per constraint
  --strict (-s)
  # Keys the rules do not name are failures
  --errors (-e)
  # Raise the failures as one error; a valid record passes through
]: record -> oneof<table<path: string, rule: string, reason: string>, record> {
  let data: record = $in
  let tables: list<string> = $rules | where type == table | each {|r| $"($r.path | split cell-path | get value | str join .)." }
  # Everything a rule needs is derived once here, so the loops below run without closures.
  # ponytail: derived again on every call; take a list of records as input when a caller validates many at once
  let rows: list<record> = $rules | each {|r|
      let members: table = $r.path | split cell-path | update optional true
      let names: list<any> = $members | get value
      let at: string = $names | str join .
      # ponytail: a path crosses at most one declared table; nest deeper when a schema needs it
      mut through: oneof<string, nothing> = null
      for t in $tables { if ($at starts-with $t) { $through = $t; break } }
      let depth: int = if $through == null { 0 } else { ($through | split row . | length) - 1 }
      $r | merge {
        at: $at
        parent: ($names | drop | str join .)
        leaf: ($names | last)
        through: $through
        rest: ($names | skip $depth | str join .)
        head: ($members | first ([$depth 1] | math max) | into cell-path)
        tail: ($members | skip $depth | into cell-path)
        whole: ($members | into cell-path)
      }
    }
  mut found: list<record> = []
  mut dead: list<string> = []
  for r in $rows {
    if ($dead | is-not-empty) and ($dead | any {|d| $r.at starts-with $"($d)." }) { continue }
    mut failed: list<record> = []
    mut absent: bool = false
    if $r.through == null {
      let value: any = $data | get $r.whole
      $absent = $value == null
      $failed = verdicts $r $r.at $value
    } else {
      for e in ($data | get $r.head | enumerate) {
        $failed ++= verdicts $r $"($r.through)($e.index).($r.rest)" ($e.item | get $r.tail)
      }
    }
    if $r.type in [record table] and ($absent or ($failed | is-not-empty)) { $dead ++= [$r.at] }
    $found ++= $failed
  }
  if $strict {
    let known: record = $rows | group-by parent
    for box in ($rows | where type in [record table] | select at whole | prepend {at: '' whole: null}) {
      let names: oneof<list<any>, nothing> = $known | get --optional $box.at | get --optional leaf
      # A container with no declared children is open.
      if $names == null or $box.at in $dead { continue }
      let held: any = if $box.at == '' { $data } else { $data | get $box.whole }
      if ($held | describe) !~ '^(record|table)' { continue }
      for key in ($held | columns | where $it not-in $names) {
        let at: string = [$box.at $key] | compact --empty | str join .
        $found ++= [{path: $at rule: unknown reason: $"($at) is not a known key"}]
      }
    }
  }
  if $errors and ($found | is-not-empty) {
    error make --unspanned {msg: ($found.reason | str join '; ') code: 'internal::validate::rules_failed'}
  }
  if $errors { $data } else { $found }
}
