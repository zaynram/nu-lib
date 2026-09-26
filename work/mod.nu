# Ticket files, the local surface of Todoist tickets: `<repo>/docs/tickets/<slug>.toml` (v4 `ticket` schema).
# Spec: `work/docs/2026-09-18_dev-core.spec.md`.

# ——— imports ——————————————————————————————————————————————————————————————————

use ../completion "into completions"
use ../validate
use ../repo

# ——— aliases ——————————————————————————————————————————————————————————————————

# ——— constants ——————————————————————————————————————————————————————————————

const VERSION: string = '4.0.0'
const STATUSES: list<string> = [draft open done aborted]
const ATTRIBUTION: list<string> = ['-human' '-agent' '-mixed']
const SLUG: string = '^[a-z0-9]+([+-][a-z0-9]+)*$'

# The v4 schema (spec, Schema), one rule per key in canonical order. `validate rules` judges a document against
# it and `normalise` takes its key order from it. The maximums are lenient starting points, about twice the
# longest value in the v3 corpus; tune them from use.
# ponytail: `ticket.reference` has no child rules, so it stays open until `dev sync` (plan Phase 5a) defines its mirrors
const RULES: list<record> = [
  {path: $.version type: string required: true}
  {path: $.ticket type: record required: true}
  {path: $.ticket.name type: string max-length: 80}
  {path: $.ticket.slug type: string required: true pattern: $SLUG max-length: 64 help: 'use lowercase letters, digits, - and +, no dots'}
  {path: $.ticket.date type: 'string|datetime' required: true}
  {path: $.ticket.status type: string required: true enum: $STATUSES}
  {path: $.ticket.target type: string max-length: 64}
  {path: $.ticket.outcome type: string required: true max-length: 1000}
  {path: $.ticket.requirements type: 'list<string>' required: true max-items: 12 max-length: 500}
  {path: $.ticket.constraints type: 'list<string>' required: true max-items: 12 max-length: 500}
  {path: $.ticket.extends type: 'list<string>' max-items: 8 pattern: $SLUG help: 'each entry is a ticket slug'}
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

# The keys `edit --set` may touch: the file-owned ones (spec, Ownership).
const SETTABLE: list<string> = [name date status target outcome requirements constraints extends output scope landscape bindings]
# Lists the writer keeps even when empty.
const KEPT: list<string> = [requirements constraints labels]

# ——— completions —————————————————————————————————————————————————————————————

def _slugs []: nothing -> record { files | select slug repo | rename value description | into completions }
def _repos []: nothing -> record { repo list | rename --column={name: value} | insert description {|row| $row | format pattern '[{owner}] {directory}' } | into completions }
def _statuses []: nothing -> record { $STATUSES | into completions }
def _properties [context: string]: nothing -> record {
  let slugs: list<string> = files | get slug
  let slug: oneof<string, nothing> = $context | split row ' ' | where $it in $slugs | get 0?
  # Bound with `let`: a `try` in tail position does not catch once the caller pipes the result onward.
  let paths: list<string> = if $slug == null { [] } else {
    try { main $slug | get ticket | columns | wrap key | format pattern 'ticket.{key}' | prepend [version ticket tasks] } catch { [] }
  }
  $paths | into completions
}

# ——— definitions —————————————————————————————————————————————————————————————

# Load and validate a ticket; `--md` renders the remote issue body instead.
@category development
@example 'read one property of a ticket' { dev hooks-placement | get ticket.status }
export def main [
  slug: string@_slugs
  --repo (-r): string@_repos # Repository to look in when the slug exists in more than one
  --md # Render the ticket as the remote issue body (Markdown) instead of returning the record
]: nothing -> oneof<record, string> {
  let file: record = locate $slug $repo
  let doc: record = open $file.path
  let bad: oneof<record, nothing> = $doc | check $file
  if $bad != null { error make --unspanned ($bad | format pattern $"'($file.path)'{reason}; {next}") }
  $doc | normalise | if $md { render } else { }
}

# Tickets across the registered repositories.
@category development
@example 'open tickets, newest first' { dev list --status open }
export def list [
  --status (-s): string@_statuses
  --repo (-r): string@_repos
]: nothing -> table<slug: string, name: string, status: string, date: datetime, repo: string> {
  # A `for`, not `each`: a closure wraps the load error of a broken file, hiding the message that names it.
  mut rows: list<record> = []
  for f in (files $repo) {
    $rows ++= [(main $f.slug --repo=$f.repo | get ticket | select slug name status date | insert repo $f.repo)]
  }
  $rows
  | if $status != null { where status == $status } else { }
  | sort-by --custom {|a b| if $a.date == $b.date { $a.slug < $b.slug } else { $a.date > $b.date } }
}

# One property of a ticket.
@category development
@example 'the outcome of a ticket' { dev query hooks-placement ticket.outcome }
export def query [
  slug: string@_slugs
  property: cell-path@_properties
  --repo (-r): string@_repos
]: nothing -> oneof<string, int, bool, datetime, list<any>, record, table, nothing> {
  # Bound with `let`: a `try` in tail position does not catch once the caller pipes the result onward.
  let out = main $slug --repo=$repo
    | try { get $property } catch {
      error make --unspanned $"no property ($property | to text | str replace '$.' '') in '($slug)'; run `dev ($slug)` to see the record"
    }
  return $out
}

# Change a ticket and rewrite its file canonically; returns the path.
@category development
@example 'open a ticket' { dev edit hooks-placement --set {status: open} }
export def edit [
  slug: string@_slugs
  --repo (-r): string@_repos
  --set: record # Merged into `ticket` (D14)
  --add-task: record # `{content, description?, labels?}`, created in Todoist first
  --complete: list<string> = [] # Task contents to complete, in Todoist first
]: nothing -> path {
  if $set == null and $add_task == null and ($complete | is-empty) {
    error make --unspanned 'nothing to edit: pass `--set`, `--add-task` or `--complete`'
  }
  let file: record = locate $slug $repo
  let doc: record = main $slug --repo=$file.repo
  # ponytail: the Todoist write-through ships with `dev sync` (plan Phase 5a); until then no ticket is linked for it
  if $add_task != null or ($complete | is-not-empty) {
    error make --unspanned $"'($slug)' has no Todoist task yet; run `dev sync ($slug)` first"
  }
  let foreign: list<string> = $set | columns | where $it not-in $SETTABLE
  if ($foreign | is-not-empty) {
    error make --unspanned $"`--set` takes ($SETTABLE | drop | str join ', ') and ($SETTABLE | last); '($foreign.0)' is not one of them"
  }
  let merged: record = $doc | update ticket { merge deep --strategy=overwrite $set }
  let bad: oneof<record, nothing> = $merged | check $file
  if $bad != null {
    error make --unspanned $'`--set` rejected: ($bad.reason | str replace --regex '^:? ' ''); nothing written'
  }
  $merged | normalise | write $file.path
}

# ——— internals ———————————————————————————————————————————————————————————————

# Ticket files of the registered repositories, or of `repo` alone.
def files [repo?: string]: nothing -> table<slug: string, repo: string, path: path> {
  let registry: list<record> = repo list | default []
  if $repo != null and $repo not-in ($registry | get $.name?) { error make --unspanned $"no registered repository named '($repo)'; run repo list to see them" }
  $registry | where $repo == null or name == $repo | par-each {|r|
    let d: path = $r.directory | path join docs tickets
    mkdir $d; glob $"($d)/*.toml"
    | par-each {|p| path parse | {slug: $in.stem repo: $r.name path: $p} }
  } | flatten --all
}

# The one file a slug names (D3).
def locate [slug: string repo?: string]: nothing -> record<slug: string, repo: string, path: path> {
  files $repo | where slug == $slug | match ($in | length) {
    0 => (error make --unspanned $"no ticket named '($slug)' in the registered repositories; run dev list to see them")
    1 => { first }
    _ => { error make --unspanned $"slug '($slug)' found in repos ($in.repo | str join ', '); pass `--repo`" }
  }
}

# The first failed check of a document, as `{reason, next}`; null when it is a valid v4 ticket (spec, Behaviour).
# The version gate comes first, then `RULES` under `--strict`, then the checks a rule cannot state: the file's
# name, a date that parses, the attribution labels.
# `reason` opens with its own joiner (` is …` or `: …`) so the loader can prefix the path verbatim.
def check [file: record]: record -> oneof<record, nothing> {
  let doc: record;
  if $doc.version? == '3.0.0' {
    return {
      reason: ' is version 3.0.0'
      next: $'move it to docs/issues/($file.slug).issue.toml, then run `dev migrate ($file.slug)`'
    }
  }
  let default: string = $'edit ($file.path) then re-run `dev ($file.slug)`'
  if $doc.version? != $VERSION {
    return {
      reason: $" is version '($doc.version)'"
      next: $'only "4.0.0" loads and "3.0.0" migrates; ($default)'
    }
  }
  match ($doc | validate rules --strict $RULES).0? {
    {path: ticket.slug rule: pattern reason: $r} => {
      reason: $': ($r)'
      next: $'rename the file and ticket.slug, then re-run `dev ($file.slug)`'
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
