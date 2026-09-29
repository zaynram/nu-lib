# /work/dev/nu/work/ticket/mod.nu

# TODO:
# - finish extraction of `ticket`-scoped methods and constants from `../mod.nu` (work)
# - update the validation and rule handling in this module for compatibility with the `validate rules` overhaul

use ../../validate rules

export const VERSION: string = '4.0.0'
export const STATUSES: list<string> = [draft open done aborted]
export const ATTRIBUTION: list<string> = ['-human' '-agent' '-mixed']
export const SLUG: string = '^[a-z0-9]+([+-][a-z0-9]+)*$'

# The keys `edit --set` may touch: the file-owned ones (spec, Ownership).
const SETTABLE: list<string> = [name date status target outcome requirements constraints extends output scope landscape bindings]
# Lists the writer keeps even when empty.
const KEPT: list<string> = [requirements constraints labels]

# The v4 schema (spec, Schema), one rule per key in canonical order. `validate rules` judges a document against
# it and `normalise` takes its key order from it. The maximums are lenient starting points, about twice the
# longest value in the v3 corpus; tune them from use.
# ponytail: `ticket.reference` has no child rules, so it stays open until `dev sync` (plan Phase 5a) defines its mirrors
export const RULES: list<record> = [
  {path: $.version type: string required: true}
  {path: $.ticket type: record required: true}
  {path: $.ticket.name type: string max-length: 80}
  {path: $.ticket.slug type: string required: true pattern: $SLUG max-length: 64 class: 'lowercase letters, digits, - and +, no dots'}
  {path: $.ticket.date type: 'string|datetime' required: true}
  {path: $.ticket.status type: string required: true enum: $STATUSES}
  {path: $.ticket.target type: string max-length: 64}
  {path: $.ticket.outcome type: string required: true max-length: 1000}
  {path: $.ticket.requirements type: 'list<string>' required: true max-items: 12 max-length: 500}
  {path: $.ticket.constraints type: 'list<string>' required: true max-items: 12 max-length: 500}
  {path: $.ticket.extends type: 'list<string>' max-items: 8 pattern: $SLUG class: 'lowercase letters, digits, - and +, no dots'}
  {path: $.ticket.output type: table max-items: 16}
  {path: $.ticket.output.path type: string required: true max-length: 200}
  {path: $.ticket.output.purpose type: string required: true max-length: 500}
  {path: $.ticket.output.alias type: string max-length: 40}
  {path: $.ticket.scope type: record}
  {path: $.ticket.scope.excluded type: table max-items: 12}
  {path: $.ticket.scope.excluded.item type: string required: true max-length: 500}
  {path: $.ticket.scope.excluded.deferred type: 'string|bool' max-length: 100}
  {path: $.ticket.landscape type: table max-items: 24}
  {path: $.ticket.landscape.scope type: string required: true enum: [internal external]}
  {path: $.ticket.landscape.synopsis type: string required: true max-length: 1000}
  {path: $.ticket.landscape.reference type: string max-length: 200}
  {path: $.ticket.landscape.type type: string max-length: 40}
  {path: $.ticket.landscape.incompatibility type: string max-length: 500}
  {path: $.ticket.bindings type: table max-items: 16}
  {path: $.ticket.bindings.kind type: string required: true max-length: 40}
  {path: $.ticket.bindings.item type: string required: true max-length: 500}
  {path: $.ticket.bindings.type type: string required: true max-length: 40}
  {path: $.ticket.bindings.conditions type: 'list<string>' max-items: 8 max-length: 300}
  {path: $.ticket.reference type: record}
  {path: $.tasks type: table max-items: 24}
  {path: $.tasks.content type: string required: true max-length: 200}
  {path: $.tasks.description type: string max-length: 2000}
  {path: $.tasks.labels type: 'list<string>' max-items: 8 max-length: 60}
  {path: $.tasks.completed type: bool}
]

# Verify a fieldset contains only settable items.
export def verify-settable [
  --return (-r) # Return the pipeline input if it passes verification
]: record -> oneof<error, nothing, record> {
  match ($in | columns | where $SETTABLE not-has $it) {
    [$0 ..] => {
      error make --unspanned {
        msg: $"'($0)' is not a settable ticket field"
        code: 'work::ticket::invalid_field_unsettable'
        help: $'settable fields: ($SETTABLE)'
      }
    }
    _ if $return => ()
  }
}

export def format-error-details [doc: record path: path]: record<reason: string, hint: string> -> record<msg: string, help: string> {
  transpose key value | update $.value {||
    let template: string = str replace '%s' $"'($path)'"
    $doc | format pattern $template
  } | transpose --ignore-titles --header-row --as-record
}

def _initial_checks []: record -> oneof<nothing, error> {
  let doc: record;
  for row in [
    [test details];
    [
      { $doc has version and $doc.version!? == '3.0.0' }
      {
        msg: "%s is version {version} (`*.issue.toml` format)"
        help: 'move it to `docs/issues` with suffix `.issue.toml` and run `migrate {slug}`'
      }
    ]
    [
      { $doc has version and $doc.version!? != $VERSION }
      {
        msg: $"%s is version {version} which is incompatible with the v($VERSION) ticket format"
        help: $'update the file to be compatible with v($VERSION) and try again'
      }
    ]
  ] { if (do --capture-errors $row.test) { error make --unspanned $row.details } }
}

# The first failed check of a document, as `{reason, next}`; null when it is a valid v4 ticket (spec, Behaviour).
# The version gate comes first, then `RULES` under `--strict`, then the checks a rule cannot state: the file's
# name, a date that parses, the attribution labels.
# `reason` opens with its own joiner (` is …` or `: …`) so the loader can prefix the path verbatim.
export def check [file: record]: record -> oneof<record, nothing> {
  let doc: record;
  let default: record = {msg: 'document validation did not succeed' help: $"edit %s then re-run `work {slug}`"}

  try {
    $doc | _initial_checks
    let violations = $doc | rules --strict $RULES
    match ($doc | rules --strict $RULES).0? {
      {path: ticket.slug rule: pattern reason: $r} => {
        msg: $': ($r)'
        help: $'rename the file and ticket.slug, then re-run `dev ($file.slug)`'
      }
      {path: _ rule: _ reason: $r} => {
        reason: $': ($r)'
        next: $default
      }
      null if $doc.ticket.slug != $file.slug => {
        reason: $": ticket.slug is '($doc.ticket.slug)' but the file is named '($file.slug)'"
        next: $'rename one, then re-run `dev [($file.slug)|($doc.ticket.slug)]`'
      }
      null if (try { $doc.ticket.date | into datetime }) == null => {
        reason: $": ticket.date '($doc.ticket.date)' is not a datetime"
        next: $'write "YYYY-mm-dd", then re-run `dev ($file.slug)`'
      }
      null if ($doc.tasks!? | is-not-empty) => {
        let tasks: table = $doc.tasks
        for row in $tasks {
          let template: string = $": task '($row.content)' has {value}; {context}"
          let marks: list<string> = $row.labels? | default [] | where $it starts-with '-'
          let regex: string = $"^\(($ATTRIBUTION | str join `|`))$"
          for rule in [
            [check value context];
            [{|| ($marks | length) > 1 } $"labels ($marks)" 'tasks must contain at most 1 attribution label']
            [{|| ($marks | where $it !~ $regex | is-not-empty) } $"label '($marks | where $it !~ $regex | first)'" $'which is not one of ($ATTRIBUTION)']
          ] {
            if (do --ignore-errors $rule.check | into bool --relaxed) {
              return {reason: ($rule | format pattern $template) next: $default}
            }
          }
        }
      }
    }
  } catch {|err|
    $err.details!
  } | if $in != null {
    format-error-details $doc $file.path
  }
}

# Rows with every one of `keys` present, in that order.
def fill-rows [...keys: string]: oneof<list<record>, nothing> -> list<record> {
  let rows: list<record> = default []
  let blank: record = $keys | reduce --fold={} {|k acc| $acc | insert $k (if $k == labels { [] } else { null }) }
  $rows | par-each --keep-order {|row| $blank | merge $row }
}

# Every `ticket` key and row column present, in the order `RULES` names them, `date` as a datetime (spec, Schema).
def normalise []: record -> record {
  let doc: record;
  # The child keys of every container: `{ticket: [name slug …], 'ticket.output': [path purpose alias], …}`.
  let shape: record = $RULES
    | par-each --keep-order {|r| $r.path | split cell-path | get value | {parent: ($in | drop | str join .) key: ($in | last)} }
    | group-by parent
  let blank: record = $shape | get ticket | get key | reduce --fold={} {|k| insert $k null }
  {
    version: $doc.version
    ticket: (
      $blank
      | merge $doc.ticket
      | update date { into datetime }
      | update output { fill-rows ...($shape | get 'ticket.output' | get key) }
      | update scope { {excluded: ($in.excluded? | fill-rows ...($shape | get 'ticket.scope.excluded' | get key))} }
      | update landscape { fill-rows ...($shape | get 'ticket.landscape' | get key) }
      | update bindings { fill-rows ...($shape | get 'ticket.bindings' | get key) }
    )
    tasks: ($doc.tasks? | fill-rows ...($shape | get tasks | get key) | default false completed)
  }
}

# Drop nulls, empty optional lists and the records they leave empty (spec, Schema).
# nu-lint-ignore: missing_in_type, missing_output_type
def prune []: any -> any {
  match ($in | describe | str replace --regex '<.*' '') {
    record => {
      transpose key value
      | par-each --keep-order {|| update value { prune } }
      | where not ($it.value == null or (($it.value | describe) =~ '^(list|table|record)') and ($it.value | is-empty) and $it.key not-in $KEPT)
      | reduce --fold={} {|e| insert $e.key $e.value }
    }
    list | table => { par-each --keep-order { prune } }
    _ => { }
  }
}

# The writer shared by every command that changes a file: canonical, atomic, null-free (spec, Behaviour).
def write [path: path]: record -> path {
  let text: string = update ticket.date { format date %F } | prune | to toml
  let dir: path = $path | path dirname
  mkdir $dir
  let temp: path = mktemp --tmpdir-path $dir --suffix .toml
  $text | save --force $temp
  mv --force $temp $path
  $path
}

def section [title: string]: oneof<string, nothing> -> oneof<string, nothing> {
  if ($in | is-empty) { return } else { $"## ($title)\n\n($in)" }
}

def md-table []: table -> oneof<string, nothing> {
  if ($in | is-empty) { return null } else {
    let rows: table;
    let blank: list<string> = $rows | columns | where ($rows | get $it | all { $in == null })
    $rows | reject ...$blank | to md
  }
}

# The remote issue body (spec, `--md`).
def render []: record -> string {
  let doc: record = $in
  let t: record = $doc.ticket
  let bullets: closure = { default [] | wrap item | format pattern '- {item}' | str join "\n" }
  [
    $'# ($t.name | defaiult $t.slug)'
    $t.outcome
    ($t.requirements | do $bullets | section Requirements)
    ($t.constraints | do $bullets | section Constraints)
    ($t.extends | do $bullets | section Extends)
    ($t.output | md-table | section Output)
    ($t.scope.excluded | md-table | section 'Out of scope')
    ($t.landscape | md-table | section Landscape)
    (
      $t.bindings
      | par-each --keep-order {|b| [($b | format pattern '- {kind}/{type}: {item}') ...($b.conditions | do $bullets)] }
      | flatten
      | str join "\n"
      | section Bindings
    )
    (
      $doc.tasks
      | insert box {|r| if $r.completed { 'x' } else { ' ' } }
      | format pattern '- [{box}] {content}'
      | str join "\n"
      | section Tasks
    )
  ] | compact --empty
  | str join "\n\n"
}
