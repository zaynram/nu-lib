# Suite of validation tools to assist with custom command definitions and parameter validation.

# nu-lint-ignore-file: do_not_compare_booleans, never_space_split

# `validate string` returns a closure intentionally (its labels carry spans, which only mean something in the caller's scope):
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.
# - Returning raw details records would require each consumer to typecheck the return value
# - Closure values allow for ergonomic usage - `... | validate string <regex> | do $in`
# - Validation error reporting can be handled in a single line, with re-assignment support for valid items.
#
# `validate rules` returns its failures as data instead: its messages name the path themselves, so no span is needed,
# and callers reword them. `--errors` raises them for callers that only want a guard.

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/str align
use /work/dev/nu/types "cell-path join"

# ——— constants ————————————————————————————————————————————————————————————————

const RULE_PRESETS: record = {
  foreign-key: {
    reason: 'key is not one of the allowed properties'
    hint: 'ensure {at} is a valid property'
    syntax: false
  }
  mandatory: {
    reason: 'value is missing for a required field'
    hint: '{at} must be a non-null value'
    syntax: false
  }
  typecheck: {
    reason: 'value is not the expected type'
    hint: '{at} has type {actual}; expected {type}'
    syntax: true
  }
  max-items: {
    reason: 'value has more elements than allowed'
    hint: '{at} has {count} items (max: {max})'
    syntax: true
  }
  min-items: {
    reason: 'value does not have enough elements'
    hint: '{at} has {count} items (min: {min})'
    syntax: true
  }
  enumerable: {
    reason: 'value is not one of the allowed values'
    hint: r#'{at} is `{actual}`, which is not one of {enum}'#
    syntax: true
  }
  regex-simple: {
    reason: 'value does not match the expected pattern'
    hint: $"{at} is (ansi g)'{actual}'(ansi rst) which does not match (ansi g)'{regex}'(ansi rst)"
    syntax: false
  }
  regex-class: {
    reason: 'value does not satisfy the regular expression'
    hint: $"{at} is (ansi g)'{actual}'(ansi rst); expected {class} \((ansi g)'{regex}'(ansi rst))"
    syntax: false
  }
  max-length: {
    reason: 'value has more characters than allowed'
    hint: '{at} is {length} characters (max: {max})'
    syntax: true
  }
  min-length: {
    reason: 'value does not have enough characters'
    hint: '{at} is {length} characters (min: {min})'
    syntax: true
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

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

# Validate a record against a table of rules. Returns one row per failure if validation errors occur.
#
# RULES:
# - `path`: Single cell-path indicating the rule's target (e.g. `$.x.y`)
# - `type`: Nushell type declaration as a string (e.g. `list<int>`)
# - `required`: Boolean indicating if the target of this rule is mandatory (omission treated as non-required)
# - `enum`: List of allowed values for the target (e.g. `[red green blue]`)
# - `pattern`: Regex pattern that the target text (bare string or string elements of a list) must satisfy
# - `class`: No-op if `pattern` is not present; additional text to clarify the pattern's requirements (e.g. `{pattern: '^[a-z]+$' class: "lowercase letters"}`)
# - `[min|max]-length`: Length restrictions applied to target text (bare strings or string elements of a list)
# - `[min|max]-items`: Element count restrictions applied to iterables (tables or lists)
#
# NOTES:
# - If a `path` passes through a `table`, that rule is judged on every row of that table.
# - Rules for a container come before the rules for its children
#   - This means that the children of an absent or failed container are not judged.
@category test
@example 'every failure as a row' {
  {name: 5} | validate rules [{path: $.name type: string required: true} {path: $.size type: int required: true}] | get hint
} --result ['$.name has type int; expected string' '$.size must be a non-null value']
@example 'a guard in a pipeline' { {name: a} | validate rules [{path: $.name type: string}] --errors } --result {name: a}
export def rules [
  rules: table
  # One row per constraint
  --strict (-s)
  # Keys the rules do not name are failures
  --errors (-e)
  # Raise the failures as one error; a valid record passes through
  --return (-r): string@[input nothing table] = input
  # Return value when validation succeeds
  # - `'input'` means return `$in` (data; default)
  # - `'nothing'` means return `null` (default for unmatched `--return` values)
  # - `'table'` means return `[]` (empty list; consistent shape)
  --colors (-c) = true
  # Use ANSI coloring in error messages and context hints
]: record -> oneof<table<path: cell-path, rule: string, reason: string, hint: string>, record> {
  let data: record;
  let tables: list<string> = $rules
    | where type starts-with table
    | par-each --keep-order {|| get $.path | split cell-path | get $.value | append '' | str join . }

  # Everything a rule needs is derived once here, so the loops below run without closures.
  # ponytail: derived again on every call; take a list of records as input when a caller validates many at once
  let rows: list<record> = $rules
    | par-each --keep-order {|row|
      let members: table = $row.path | split cell-path | update optional true
      let repr: string = $members.value | str join .
      # ponytail: a path crosses at most one declared table; nest deeper when a schema needs it
      let through: oneof<list<string>, nothing> = $tables | where $repr starts-with $it | if $in != [] { first | split row . | drop }
      let depth: int = $through | if $in == null { 0 } else { length }
      $row | merge {
        at: ($members.value | into cell-path)
        parent: ($members.value | drop | str join .)
        leaf: ($members.value | last)
        through: $through
        rest: ($members.value | skip $depth)
        head: ($members | first ([$depth 1] | math max) | into cell-path)
        tail: ($members | skip $depth | into cell-path)
        whole: ($members | into cell-path)
      }
    }

  let result: record = $rows
    | reduce --fold={found: [] dead: []} {|it acc|
      if $acc.dead != [] or ($acc.dead | under $it.at) { return $acc }
      let t: string = $it.type
      let container: bool = [record table] | any ($t starts-with $it)
      if $it.through == null {
        let x: any = $data | get $it.whole
        let v: table = $x | verdicts $it.at $it
        if $container and ($x == null or $v != []) {
          {dead: [...$acc.dead $it.at] found: [...$acc.found ...$v]}
        } else if $v != [] {
          $acc | update $.found [...$in.found ...$v]
        }
      } else {
        let v: table = $data | get $it.head | enumerate | par-each --keep-order {|row|
            let at: cell-path = [...$it.through $row.index ...$it.rest] | compact --empty | into cell-path
            $row.item | get $it.tail | verdicts $at $it
          } | flatten --all
        if $v != [] { $acc | update $.found [...$in.found ...$v] }
      } | default $acc
    }

  let found: table = if $strict {
    let known: record = $rows | group-by parent
    [{at: $. whole: null} ...($rows | where type in [record table] | select $.at $.whole)]
    | reduce --fold=[] {|box acc|
      # A container with no declared children is open; one that failed, or sits under one that did, cannot be scanned.
      if $result.dead != [] and ($result.dead | under $box.at) { return }
      let names: list = $known | get --optional $"($box.at).leaf" | default []
      match $box { _ if $names == [] => { return } {at: ''} => $data {whole: $w} => ($data | get $w) }
      | if ($in | describe) !~ '^(record|table)' { return } else { columns | difference $names }
      | par-each --keep-order {|name| failure foreign-key {at: ($box.at | cell-path join $name)} }
      | prepend $acc
    }
  } | prepend $result.found
    | compact --empty

  $found | if $in == [] {
    return (match $return { table => [] nothing => null _ => $data })
  } else if $colors { } else {
    ansi strip $.reason $.hint
  } | if $errors {
    enumerate
    | flatten item
    | str trim
    | format pattern "[{index}]: {hint}"
    | align ':'
    | error make --unspanned {
      msg: 'validation completed with errors'
      code: 'validate::rules::validation_failed'
      help: $in
    }
  } else {
    return $in
  }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Does `value` have `type`: a `describe` name, `record`, `table`, `list<inner>`, or alternatives joined by `|`.
def fits [value: any type: string]: nothing -> bool {
  let kind: string = $value | describe
  if $kind == $type { return true }
  for t in ($type | split row '|') {
    [
      { $t == record and $kind starts-with record }
      { $t == table and ($kind starts-with table) or (($kind starts-with list) and ($value | all (($it | describe) starts-with record))) }
      { $t starts-with list< and ($kind =~ '^(list|table)') and ($value | all (fits $it ($t | str substring 5..-2))) }
      { $kind == $t }
    ] | if ($in | any (do $it)) { return true }
  }
  return false
}

# Is `at` one of the `dead` containers, or under one.
# This runs once per rule, and entering a closure command costs about ten times what the loop does.
# - 2026-09-26: swapped back to `any` from `for` but with subexpression evaluation instead of closure
def under [at: cell-path]: list<cell-path> -> bool {
  any ($at == $it or ($at | split cell-path).0?.value == $it)
}

# One failure row, with rule based dynamic style application.
# - Styles are stripped by request with `validate rules --colors=false`
def failure [
  rule: string@_presets
  # Key of a pre-configured rule, or a standalone string
  context: record<at: cell-path>
  # Fields to include as context to format template strings
  --custom: record<reason: string, hint: string>
  # Custom templates to fill with the context fields (required when not using a preset)
]: nothing -> record<path: cell-path, rule: string, hint: string, reason: string> {
  let preset: record = $custom | default ($RULE_PRESETS | get --ignore-case --optional $rule)
    | default {|| error make --unspanned 'custom templates are required when not using a rule preset' }
    | compact --empty
    | default false syntax
  let fields: record = $context
    | if $preset.syntax {
      transpose key value
      | update $.value { $'($in)' | nu-highlight }
      | transpose --ignore-titles --header-row --as-record
    } else {
      update $.at ($'($in.at)' | nu-highlight)
    }
  match $preset {
    {hint: $h reason: $r} => {
      path: $context.at
      rule: $rule
      hint: ($fields | format pattern $h)
      reason: ($fields | format pattern $r)
    }
    {hint: _} => { error make --unspanned 'no reason template was provided' }
    {reason: _} => { error make --unspanned 'no hint template was provided' }
    _ => { error make --unspanned 'no reason or hint templates were provided' }
  }
}

def is-iterable [type?: string]: oneof<any, nothing> -> bool { let it: any; $type | default ($it | describe) | $in =~ '^(list|table)' }

# The failures of one rule at one place.
# The `enum`, `pattern` and `max-length` rules also run on each element of a list.
def verdicts [
  at: cell-path
  rule: record
]: oneof<nothing, any> -> table<path: cell-path, rule: string, msg: string, help: string> {
  let x: any;
  let t: string = $x | describe
  let i: bool = is-iterable $t
  let o: table = match $t {
    nothing if $rule not-has required or not $rule.required => []
    nothing if $rule has required => [(failure mandatory {at: $at})]
    _ if not (fits $x $rule.type) => [(failure typecheck {at: $at type: $rule.type actual: $t})]
    _ if $i => [($x | check-iter-count $at --min=$rule.min-items? --max=$rule.max-items?)]
  } | default [] | compact
  if ($rule | columns | any ($it =~ '^(min-|max-|enum|pattern)')) {
    if $i { $x | enumerate | update $.index {|row| $at | cell-path join $row.index } | rename --column={index: at item: value} }
    | default [[at value]; [$at $x]]
    | par-each --keep-order {|p|
      let type: string = $p.value | describe
      let text: bool = $type =~ '^(string|list<string>)$'
      let iter: bool = is-iterable $type
      [
        (if $iter { $p.value | check-iter-count $p.at --min=$rule.min-items? --max=$rule.max-items? })
        ...(if $rule.enum? != null { $p.value | check-enum-member --iterable=$iter $p.at $rule.enum })
        ...(if $text { $p.value | check-text-length --iterable=$iter $p.at --min=$rule.min-length? --max=$rule.max-length? })
        ...(if $text and $rule.pattern? != null { $p.value | check-regex-match --iterable=$iter $p.at $rule.pattern --class=$rule.class? })
      ] | compact --empty
    } | flatten --all
  } | prepend $o
}

def check-enum-member [
  at: cell-path
  enum: list<any> # nu-lint-ignore: list_param_to_variadic
  --iterable
]: oneof<any, list<any>> -> oneof<list<any>, table> {
  if $iterable { enumerate } else { append [] }
  | each --flatten {|it|
    match $it {
      {index: $n item: $x} => {at: ($at | cell-path join $n) actual: $x enum: $enum}
      _ => {at: $at actual: $it enum: $enum}
    } | if $enum not-has $in.actual { failure enumerable $in }
  }
}

def check-regex-match [
  at: cell-path
  pattern: string
  --class: string
  --iterable
]: oneof<string, list<string>> -> oneof<list<any>, table> {
  if $iterable { enumerate } else { append [] }
  | each --flatten {|it|
    match $it {
      {index: $n item: $x} => {at: ($at | cell-path join $n) actual: $x regex: $pattern class: $class}
      _ => {at: $at actual: $it regex: $pattern class: $class}
    } | compact | if $in.actual =~ $pattern {
      return
    } else if $in has class {
      failure regex-class $in
    } else {
      failure regex-simple $in
    }
  }
}

def check-text-length [
  at: cell-path
  --min: int
  --max: int
  --iterable
]: oneof<nothing, string, list<string>> -> oneof<list<any>, table> {
  if $iterable { enumerate } else { append [] }
  | each {|it|
    match $it {
      {index: $n item: $x} => {at: ($at | cell-path join $n) length: ($x | str length --chars) min: $min max: $max}
      _ => {at: $at length: ($it | str length --chars) min: $min max: $max}
    } | compact | match $in {
      {min: $m length: $l} if $l < $m => (failure min-length $in)
      {max: $m length: $l} if $l > $m => (failure max-length $in)
    }
  }
}

def check-iter-count [
  at: cell-path
  --min: int
  --max: int
]: oneof<list, table> -> oneof<nothing, record> {
  let size: int = length
  match ({min: $min max: $max} | compact) {
    {min: $m} if $size < $m => (failure min-items {at: $at count: $size min: $m})
    {max: $m} if $size > $m => (failure max-items {at: $at count: $size max: $m})
  }
}

def _presets []: any -> list<string> { $RULE_PRESETS | columns }
