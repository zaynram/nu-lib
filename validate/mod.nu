# Suite of validation tools to assist with custom command definitions and parameter validation.

# nu-lint-ignore-file: do_not_compare_booleans, never_space_split, missing_in_type, list_param_to_variadic

# `validate string` returns a closure intentionally (its labels carry spans, which only mean something in the caller's scope):
# - Raising from a nested scope causes error duplication as the error propagates upwards.
# - Returning raw details records would require each consumer to typecheck the return value
# - Closure values allow for ergonomic usage - `... | validate string <regex> | do $in`
# - Validation error reporting can be handled in a single line, with re-assignment support for valid items.
#
# `validate rules` returns its failures as data instead: its messages name the path themselves, so no span is needed,
# and callers reword them. `--errors` raises them for callers that only want a guard.

# ——— imports ——————————————————————————————————————————————————————————————————

use error
use std-rfc/str align
use style
use types "cell-path join"

# ——— constants ————————————————————————————————————————————————————————————————

# A type alternative whose rows are judged one by one: `table`, and lists of records (`list<record>`,
# `list<record<…>>`). Matched per alternative of a rule type (`is-table-type`), so `nothing|table` counts too.
const TABLE_TYPE: string = '^(table|list<record[<>])'
# A type alternative `--strict` scans for undeclared keys: records and the table types (`is-container-type`).
const CONTAINER_TYPE: string = '^(record|table|list<record[<>])'
const RETURNS: list<string> = [one input nothing table]
# Tables with more rows than this are judged with `par-each` (rules without `dynamic` closures only).
const PARALLEL_ROWS: int = 64

# A preset's `syntax: true` highlights every context field as nu code; `syntax: false` highlights `{at}` only and
# shows the `literal` fields as quoted, green strings. `failure` always styles; `validate rules` strips afterwards.
const RULE_PRESETS: record = {
  any-const: {
    reason: 'value is not the expected constant'
    hint: '{at} must be exactly {const}'
    syntax: true
  }
  str-const: {
    reason: 'value is not the expected string'
    hint: '{at} must be exactly {const}'
    syntax: false
    literal: [const]
  }
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
    hint: '{at} is {actual} which does not match {regex}'
    syntax: false
    literal: [actual regex]
  }
  regex-class: {
    reason: 'value does not satisfy the regular expression'
    hint: '{at} is {actual}; expected {class} ({regex})'
    syntax: false
    literal: [actual regex]
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
  --code: string = 'validate::string::invalid_argument'
  # Error code for validation failures
  --labels: table<text: string, span: record> = []
  # Error labels for validation errors; the input and regex pattern will be included if this is empty
  --inner: oneof<nothing, error, record>
  # An inner error (a caught error, or an error record) to include in the error details for validation errors
  --instruct: string
  # Requirement description or other helpful information for additional context
]: string -> closure {
  if (($regex != null and $in =~ $regex) or $enum has $in) != $not { let s: string; {|| $s } } else {
    let value: record = metadata | {text: string span: $in.span}
    let check: record = if $regex != null { {text: regex span: (metadata $regex).span} } else { {text: enum span: (metadata $enum).span} }
    let labels: table<text: string, span: record> = $labels | default --empty [$value $check]
    # The message is the caller's `--message`, whose span lies at the call site, so the code is the caller's `--code`
    # rather than derived here; with labels, `error raise` returns the closure that raises.
    $inner | error raise $message ...{
      kind: invalid_argument
      code: $code
      labels: $labels
      advice: $instruct
    }
  }
}

def evaluate-single-rule [
  rule: record
  --bail (-b)
]: record -> oneof<nothing, table, record> {
  let data: record;
  if $rule.through == null {
    # without `bail`, a rule under an absent or failed container is already skipped by the caller
    let hidden: bool = $bail and ($rule.guards | any (($data | reach $it | get $.value?) == null))
    let reached: any = if $hidden { null } else { $data | reach $rule.whole }
    if $reached == null { return (if $bail { null } else { {item: null at: $rule.at result: []} }) }
    $reached.value | verdicts $rule.at $rule
    | if $bail {
      return $in.0?
    } else {
      return {item: $reached.value at: $rule.at result: $in}
    }
  }
  let rows: any = $data | reach $rule.head | get $.value?
  # an absent or mistyped table was (or will be) reported by its own rule; its rows cannot be judged
  if not (is-iterable ($rows | describe)) { return (if $bail { null } else { [] }) }
  if $bail {
    for row in ($rows | enumerate) {
      let reached: any = $row.item | reach-in-row $rule
      if $reached == null { continue }
      let at: cell-path = [...$rule.through $row.index ...$rule.rest] | compact --empty | into cell-path
      $reached.value
      | verdicts $at $rule
      | if $in != [] { return $in.0 }
    }
  } else {
    let judge: closure = {|row|
      let at: cell-path = [...$rule.through $row.index ...$rule.rest]
        | compact --empty
        | into cell-path
      let reached: any = $row.item | reach-in-row $rule
      {
        item: $row.item
        at: $at
        result: (if $reached == null { [] } else { $reached.value | verdicts $at $rule })
      }
    }
    # `par-each` costs about a millisecond to start; it only pays off for long tables. A rule with `dynamic`
    # closures is judged row by row regardless: they are the caller's code, which may write to shared state.
    if ($rows | length) > $PARALLEL_ROWS and $rule.dynamic? == null {
      $rows | enumerate | par-each --keep-order $judge
    } else {
      $rows | enumerate | each $judge
    }
  }
}

# The value at `path` as `{value: ...}`, or null when the path runs through something that is neither a record nor
# a table: a mistyped container is reported by its own rule (when it has one), and what lies under it is not judged.
def reach [path: cell-path]: any -> oneof<nothing, record<value: any>> {
  let box: any;
  try { {value: ($box | get $path)} } catch { null }
}

# The value a rule judges in one row of the table it runs through (see `reach`); also null when a declared
# container above it is absent from the row.
def reach-in-row [rule: record]: any -> oneof<nothing, record<value: any>> {
  let row: any;
  if ($rule.guards | any (($row | reach $it | get $.value?) == null)) { return null }
  $row | reach $rule.tail
}

# The values a `--strict` container stands for, with their paths: the container itself, or, when it sits under a
# declared table, the container in every row of that table.
def places [box: record]: record -> table<at: cell-path, value: any> {
  let data: record;
  if $box.through == null { return [{at: $box.at value: ($data | reach $box.whole | get $.value?)}] }
  let rows: any = $data | reach $box.head | get $.value?
  # an absent or mistyped table was reported by its own rule; its rows cannot be scanned
  if not (is-iterable ($rows | describe)) { return [] }
  $rows | enumerate | each {|row|
    {at: ([...$box.through $row.index ...$box.rest] | into cell-path) value: ($row.item | reach $box.tail | get $.value?)}
  }
}

# The undeclared keys of a record as `foreign-key` failures; a table (or list) is scanned row by row, each row
# under its index. Anything else has no keys to scan.
def foreign-keys [names: list<string> at: cell-path]: any -> list<record> {
  let box: any;
  match ($box | describe | str replace --regex '<.*' '') {
    record => ($box | columns | difference $names | each {|name| failure foreign-key {at: ($at | cell-path join $name)} })
    table | list => ($box | enumerate | each --flatten {|row| $row.item | foreign-keys $names ($at | cell-path join $row.index) })
    _ => []
  }
}

# Validate a record against a table of rules. Returns one row per failure if validation errors occur
# (`data` is null unless a dynamic rule attached a payload).
#
# RULES:
# - `path`: Single cell-path indicating the rule's target (e.g. `$.x.y`)
# - `type`: Nushell type declaration as a string (default `any`): a `describe` name (`int`, `string`, ...), `any`,
#   `number` (int or float), `record`, `table`, `list<inner>`, or alternatives joined by `|` (`string|datetime`,
#   `list<int|string>`). `table` also accepts a list of records, and an empty list fits every list type. A rule
#   is a `record`/`table` rule (see NOTES) when any of its alternatives is one (`nothing|table`).
# - `required`: Boolean indicating if the target of this rule is mandatory (omission treated as non-required)
# - `enum`: List of allowed values for the target (e.g. `[red green blue]`); each element of a list is judged
# - `const`: The target must equal this value exactly. When the target is a list and the constant is not, every
#   element must equal the constant instead (`{const: 1}` on `[1 1]` passes; `{const: [1 2]}` compares the list).
# - `pattern`: Regex pattern that the target text (bare string or string elements of a list) must satisfy
# - `class`: No-op if `pattern` is not present; additional text to clarify the pattern's requirements (e.g. `{pattern: '^[a-z]+$' class: "lowercase letters"}`)
# - `[min|max]-length`: Length restrictions applied to target text (bare strings or string elements of a list)
# - `[min|max]-items`: Element count restrictions applied to iterables (tables or lists)
# - `dynamic`: Record mapping one or more names to closures; every closure runs, and its name is the `rule` of
#   any failure it reports
#   - The closure is passed the value as pipeline input and first positional, and its cell-path as the second
#   - Lists and tables are iterated: the closure sees one element (one row) at a time, with the element's path
#   - The closures run one row at a time, in row order, even on a long table (whose other rules are judged in
#     parallel): a closure may write to shared state (`kv`, a file) without racing another row
#   - It passes by returning nothing (or any non-record value)
#   - It fails by raising (the error's `msg` is the `reason`, its `help` the `hint`) or by returning a record with
#     `reason` (or `msg`) and optionally `hint` (or `help`); every other field of a returned record is kept as
#     `data` on the failure row. Raising cannot carry data.
#   - `{at}` and `{<data field>}` in its reason and hint are filled in; any other `{...}` is kept as written.
#
# NOTES:
# - If a `path` passes through a `table` (or `list<record>`) rule's path, that rule is judged on every row of that
#   table, and its failures name the row (`$.rows.1.name`).
# - Rules for a container come before the rules for its children
#   - This means that the children of an absent or failed container are not judged.
#   - A path through a value that cannot hold keys (a scalar, or a list of scalars) is not judged either, even when
#     `required`, if no rule declares that container: `$.r.q` passes on `{r: 5}`. Declare the container
#     (`{path: $.r type: record}`) to have the mismatch reported. An absent undeclared container is different: a
#     `required` rule under it fails as missing.
# - `--strict` scans the root and every `record`/`table` rule that has child rules; an undeclared key in a table
#   row is reported under the row's index (`$.rows.0.typo`).
@category test
@example 'every failure as a row' {
  {name: 5} | validate rules [{path: $.name type: string required: true} {path: $.size type: int required: true}] --colors=false | get hint
} --result ['$.name has type int; expected string' '$.size must be a non-null value']
@example 'a guard in a pipeline' { {name: a} | validate rules [{path: $.name type: string}] --errors } --result {name: a}
export def rules [
  rules: oneof<table<path: cell-path, type: string>, table>
  # One row per constraint
  --strict (-s)
  # Keys the rules do not name are failures
  --errors (-e)
  # Raise the failures as one error; a valid record passes through
  --return (-r): string@$RETURNS = input
  # Return value when validation succeeds; any other value is an error
  # - `one` means return the first error record or `null` if none occur (overrides `--errors`)
  # - `'input'` means return `$in` (data; default)
  # - `'nothing'` means return `null`
  # - `'table'` means return `[]` (empty list; consistent shape)
  --colors (-c): oneof<nothing, bool>
  # Use ANSI styles in failure reasons and hints (default: `style colors`, i.e. `config use-colors`); `false`
  # strips them and `true` keeps them without a terminal, also with `--return=one`. The `--errors` help is plain
  # text either way. The flag takes a value (`--colors=true`/`--colors=false`): a bare `--colors` is an error
]: record -> oneof<nothing, table<path: cell-path, rule: string, reason: string, hint: string, data: any>, record> {
  let data: record;
  let colors: bool = $colors | default { style colors }
  if $return not-in $RETURNS {
    error raise $"invalid --return value '($return)'" ...{
      kind: invalid_argument
      labels: [
        {text: $"expected one of ($RETURNS | str join ', ')" span: (metadata $return).span}
      ]
    } | do $in
  }
  let bail: bool = $return == 'one'
  let rules: table = $rules | default any $.type
  let tables: list<string> = $rules
    | where ($it.type | is-table-type)
    | each {|| get $.path | split cell-path | get $.value | append '' | str join . }

  # Everything a rule needs is derived once here, so the loops below run without closures.
  # ponytail: derived again on every call; take a list of records as input when a caller validates many at once
  let rows: list<record> = $rules
    | each {|row|
      let members: table = $row.path | split cell-path | update optional true
      let repr: string = $members.value | str join .
      # ponytail: a path crosses at most one declared table; nest deeper when a schema needs it
      let through: oneof<list<string>, nothing> = $tables | where $repr starts-with $it | if $in != [] { first | split row . | drop }
      let depth: int = $through | if $in == null { 0 } else { length }
      $row | merge {
        at: ($members.value | into cell-path)
        repr: $repr
        parent: ($members.value | drop | str join .)
        leaf: ($members.value | last)
        through: $through
        rest: ($members.value | skip $depth)
        head: ($members | first ([$depth 1] | math max) | into cell-path)
        tail: ($members | skip $depth | into cell-path)
        whole: ($members | into cell-path)
      }
    }
  # The declared containers above a rule, as paths into what the rule reads (the document, or a row of the table
  # it runs through): when one of them is absent, the rule is not judged there.
  let boxes: table = $rows | where ($it.type | is-container-type)
  let rows: list<record> = $rows | each {|row|
    let above: table = $boxes | where ($row.repr | str starts-with $'($it.repr).')
    $row | insert guards (if $row.through == null {
      $above | where through == null | get whole
    } else {
      $above | where through != null | get tail
    })
  }

  # For `bail` mode, we use for loops and return immediately when we hit an error
  if $bail {
    for rule in $rows {
      $data
      | evaluate-single-rule $rule --bail
      | match ($in | describe) {
        nothing => (continue)
        _ => (return ($in | styled --colors=$colors))
      }
    }
    if $strict {
      for box in (containers $rows) {
        let names: list<string> = $rows | where parent == $box.repr | get leaf
        # a container with no declared children is open
        if $names == [] { continue }
        let first: any = $data | places $box | each --flatten {|place| $place.value | foreign-keys $names $place.at } | get 0?
        if $first != null { return ($first | styled --colors=$colors) }
      }
    }
    return null
  }

  # For non-`bail` mode, every rule is judged and its failures are collected, in rule order.
  # The container rules are judged first: a container that is absent, or fails its own rule, is dead, and no later
  # rule at or under its path is judged (the bail loop above gets the same effect by stopping at the first failure).
  # Only a container that is not under a declared table can be dead: one under a table is judged row by row, and
  # `reach-in-row` skips what lies under it in the rows where it is absent or mistyped.
  let indexed: table = $rows | enumerate
  let judged: table = $indexed
    | where $it.item.through == null and ($it.item.type | is-container-type)
    | each {|r|
      # a container rule yields one row; `$inter.item` is that row's value as a one-element column
      let inter: table = $data | evaluate-single-rule $r.item | append []
      let verdicts: table = $inter.result | flatten --all
      {index: $r.index at: $r.item.at verdicts: $verdicts dead: ($inter.item.0? == null or $verdicts != [])}
    }
  let dead: list<cell-path> = $judged | where dead | get at
  let verdicts: table = $indexed
    | where {|r|
      let before: list<cell-path> = $judged | where $it.dead and $it.index < $r.index | get at
      $before == [] or not ($before | under $r.item.at)
    }
    | each --flatten {|r|
      let box: oneof<nothing, record> = $judged | where index == $r.index | get $.0?
      if $box != null { $box.verdicts } else { $data | evaluate-single-rule $r.item | append [] | get result | flatten --all }
    }

  let found: table = if $strict {
    # A container with no declared children is open; one that failed, or sits under one that did, cannot be scanned.
    containers $rows
    | where not ($dead != [] and ($dead | under $it.at))
    | each --flatten {|box|
      let names: list<string> = $rows | where parent == $box.repr | get leaf
      if $names == [] { [] } else {
        $data | places $box | each --flatten {|place| $place.value | foreign-keys $names $place.at }
      }
    }
  } | prepend $verdicts
    | compact --empty

  $found | if $in == [] {
    return (match $return { table => [] nothing => null _ => $data })
  } else {
    styled --colors=$colors
  } | if $errors {
    # The advice is plain whatever `--colors` resolved to: error messages never carry ANSI.
    let help: string = $in
      | styled --colors=false
      | enumerate
      | flatten item
      | str trim
      | format pattern "[{index}]: {hint}"
      | align ':'
    error raise 'validation completed with errors' ...{
      kind: invalid_argument
      advice: $help
    }
  } else {
    return $in
  }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Does `value` have `type`: a `describe` name, `any`, `number`, `record`, `table`, `list<inner>`, or alternatives
# joined by `|` at the top level (`list<int|string>|nothing` has two alternatives).
def fits [value: any type: string]: nothing -> bool {
  let kind: string = $value | describe
  if $kind == $type { return true }
  for t in ($type | alternatives) {
    let ok: bool = match $t {
      any => true
      number => ($kind in [int float])
      record => ($kind starts-with record)
      table => (($kind starts-with table) or (($kind starts-with list) and ($value | all ($it | describe) starts-with record)))
      $l if $l starts-with 'list<' => (($kind =~ '^(list|table)') and ($value | all (fits $it ($l | str substring 5..-2))))
      _ => ($kind == $t)
    }
    if $ok { return true }
  }
  false
}

# The alternatives of a union type: split at every `|` that is not inside `<...>`.
def alternatives []: string -> list<string> {
  let type: string = $in
  if $type !~ '<.*\|' { return ($type | split row '|') }
  $type | split chars | reduce --fold={depth: 0 parts: ['']} {|c acc|
    match $c {
      '|' if $acc.depth == 0 => ($acc | update parts { append '' })
      _ => {
        depth: ($acc.depth + (match $c { '<' => 1 '>' => -1 _ => 0 }))
        parts: ($acc.parts | update (($acc.parts | length) - 1) { $in + $c })
      }
    }
  } | get parts
}

# Does a rule type name a table (`table`, `list<record>`, `list<record<…>>`) in any of its alternatives (`nothing|table`)?
def is-table-type []: string -> bool { alternatives | any ($it =~ $TABLE_TYPE) }

# Does a rule type name a container (a record or a table) in any of its alternatives (`nothing|record`)?
def is-container-type []: string -> bool { alternatives | any ($it =~ $CONTAINER_TYPE) }

# The containers `--strict` scans for undeclared keys: the root, then every declared record or table, in rule order.
# `repr` is the dotted path the children's `parent` column uses; `whole` reads the container out of the data, and
# `through`/`head`/`tail`/`rest` locate it in the rows of a declared table it sits under (see `places`).
def containers [rows: table]: nothing -> table<at: cell-path, whole: cell-path, repr: string> {
  [
    {at: $. whole: $. repr: '' through: null head: $. tail: $. rest: []}
    ...($rows | where ($it.type | is-container-type) | select $.at $.whole $.repr $.through $.head $.tail $.rest)
  ]
}

# Is `at` one of the `dead` containers, or under one.
# This runs once per rule, and entering a closure command costs about ten times what the loop does.
# - 2026-09-26: swapped back to `any` from `for` but with subexpression evaluation instead of closure
def under [at: cell-path]: list<cell-path> -> bool {
  let dead: list<cell-path>;
  let here: string = $'($at)'
  $dead | any ($at == $it or ($here | str starts-with $'($it).'))
}

# One failure row, with rule based dynamic style application.
# - Styles are always applied here (`nu-highlight`, and `style paint` forced on); `validate rules` strips them when
#   its `--colors` resolves to false, so the many callers of this command need no flag of their own.
def failure [
  rule: string@_presets
  # Key of a pre-configured rule, or a standalone string
  context: record<at: cell-path>
  # Fields to include as context to format template strings
  --custom: record<reason: string, hint: string>
  # Custom templates to fill with the context fields (required when not using a preset)
  --data: any
  # Structured payload a dynamic rule attached to its failure (a record), returned as-is in the `data` column; null otherwise
]: nothing -> record<path: cell-path, rule: string, hint: string, reason: string, data: any> {
  # Only a preset name or `--custom` templates reach here; anything else is a defect in this module.
  let preset: record = $custom | default ($RULE_PRESETS | get --ignore-case --optional $rule)
    | default {
      error raise $"'($rule)' is not a preset and no custom templates were given" --kind internal
    }
    | compact --empty
    | default false syntax
  let missing: list<string> = [reason hint] | where $preset not-has $it
  if $missing != [] {
    error raise $"the rule '($rule)' has no ($missing | str join ' or ') template" --kind internal
  }
  let literal: list<string> = $preset.literal? | default []
  let fields: record = $context | record each {|key value|
    {
      $key: (if $preset.syntax or $key == at {
        $'($value)' | nu-highlight
      } else if $key in $literal {
        $"'($value)'" | style paint g --colors=true
      } else {
        $value
      })
    }
  }
  {
    path: $context.at
    rule: $rule
    hint: ($preset.hint | fill-template $fields)
    reason: ($preset.reason | fill-template $fields)
    data: $data
  }
}

# Fill the `{name}` placeholders of a template from `fields`; a placeholder that names no field is kept as written
# (dynamic rules' reasons and hints are templates too, and may contain literal braces).
def fill-template [fields: record]: string -> string {
  let template: string = $in
  let names: list<string> = $fields | columns
  $template | split row '{' | enumerate | each {|part|
    if $part.index == 0 { return $part.item }
    let found: any = $part.item | parse --regex '(?s)^(?<key>[^{}]*)\}(?<rest>.*)$' | get 0?
    if $found != null and $found.key in $names { $"($fields | get $found.key)($found.rest)" } else { $"{($part.item)" }
  } | str join
}

# Strip the styles of failure rows (a table, or the one record `--return=one` returns) unless `--colors` is set
# (the resolved value of `validate rules --colors`).
def styled [--colors]: oneof<record, table> -> oneof<record, table> {
  if $colors { } else { ansi strip $.reason $.hint }
}

def is-iterable [type?: string]: oneof<any, nothing> -> bool { let it: any; $type | default ($it | describe) | $in =~ '^(list|table)' }

# The failures of one rule at one place.
# The `enum`, `pattern` and `max-length` rules also run on each element of a list.
def verdicts [
  at: cell-path
  rule: record
]: oneof<nothing, any> -> table<path: cell-path, rule: string, reason: string, hint: string, data: any> {
  let x: any;
  let t: string = $x | describe
  let i: bool = is-iterable $t
  let o: table = match $t {
    nothing if $rule not-has required or not $rule.required => []
    nothing if $rule has required => [(failure mandatory {at: $at})]
    _ if not (fits $x $rule.type) => [(failure typecheck {at: $at type: $rule.type actual: $t})]
    _ if $i => [($x | check-iter-count $at --min=$rule.min-items? --max=$rule.max-items?)]
  } | default [] | compact
  # A missing or mistyped value was reported above; its contents are not judged again (a list that is merely too long still is).
  let judged_out: bool = $x == null or ($o | any ($it.rule in [mandatory typecheck]))
  # `const` judges each element of a list only when the constant is not a list itself; otherwise the whole value.
  let const_whole: bool = $i and $rule has const and (is-iterable ($rule.const | describe))
  let whole: list = if not $judged_out and $const_whole { [($x | check-is-constant $at $rule.const)] | compact } else { [] }
  if not $judged_out and ($rule | columns | any ($it =~ '^(min-|max-|enum|pattern|const|dynamic)')) {
    if $i { $x | enumerate | update $.index {|row| $at | cell-path join $row.index } | rename --column={index: at item: value} }
    | default [[at value]; [$at $x]]
    | each {|p|
      let type: string = $p.value | describe
      let text: bool = $type =~ '^(string|list<string>)$' or $rule.type? == string
      let iter: bool = is-iterable $type
      # `$in` is not visible inside the subexpressions of a list literal, so the value is bound by name.
      let v: any = if $p.value != null {
        $p.value
      } else if $rule has required and $rule.required {
        return [(failure mandatory {at: $p.at})]
      } else if $iter {
        []
      } else if $text {
        ''
      } else {
        return [] # don't run validation on non-required `null` values
      }
      [
        (if $iter { $v | check-iter-count $p.at --min=$rule.min-items? --max=$rule.max-items? })
        ...(if $rule.dynamic? != null { $v | check-dynamic-rule $p.at $rule.dynamic } else { [] })
        (if $rule has const and not $const_whole { $v | check-is-constant $p.at $rule.const --string=$text })
        ...(if $rule.enum? != null { $v | check-enum-member --iterable=$iter $p.at $rule.enum } else { [] })
        ...(if $text { $v | check-text-length --iterable=$iter $p.at --min=$rule.min-length? --max=$rule.max-length? } else { [] })
        ...(if $text and $rule.pattern? != null { $v | check-regex-match --iterable=$iter $p.at $rule.pattern --class=$rule.class? } else { [] })
      ] | compact --empty
    } | flatten --all
  } | prepend $whole | prepend $o
}

# A dynamic rule fails in one of two ways, and passes by returning anything else (usually nothing):
# - raising (`error raise <reason> --advice <hint>`): the error's `msg` is the reason, its `help` the hint. Nothing
#   else survives a raised error (LabeledError keeps only its own fields), so this form carries no data.
# - returning a record with `reason` (or `msg`): `hint` (or `help`) is the hint and every other field is kept as
#   `data` on the failure row, also available to the templates (`{at}` is always available).
# Every named closure of the map runs, in order; each reports at most one failure.
def check-dynamic-rule [
  at: cell-path
  map: record
]: any -> list<record> {
  let val: any;
  $map | items {|name rule|
    let outcome: record = try {
      {returned: ($val | do --capture-errors $rule $val $at)}
    } catch {|err|
      let d: record = $err.details? | default {msg: $err.msg}
      {raised: {reason: $d.msg hint: ($d.help? | default $d.msg)}}
    }
    let verdict: record = match $outcome {
      {raised: $r} => $r
      {returned: $r} if ($r | describe) =~ '^record' and ($r has reason or $r has msg) => {
        let reason: string = $r.reason? | default $r.msg?
        let hint: string = $r.hint? | default $r.help? | default $reason
        let data: record = $r | reject $.reason? $.msg? $.hint? $.help?
        {reason: $reason hint: $hint data: $data}
      }
      _ => (return)
    }
    let data: record = $verdict.data? | default {}
    failure $name {at: $at ...$data} --custom={reason: $verdict.reason hint: $verdict.hint} --data=(if $data == {} { null } else { $data })
  } | compact
}

# A failure when the value is not exactly `const` (`str-const` for text, `any-const` otherwise).
def check-is-constant [
  at: cell-path
  const: any
  --string
]: any -> oneof<nothing, record> {
  let actual: any;
  if $actual != $const {
    failure $'(if $string { 'str' } else { 'any' })-const' {at: $at actual: $actual const: $const}
  }
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
]: oneof<nothing, string, list<string>> -> oneof<list<any>, table> {
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
