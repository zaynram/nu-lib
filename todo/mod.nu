# Todoist tasks with the `td` CLI: typed rows, completions, slug matching and an auth retry.

# ——— imports ——————————————————————————————————————————————————————————————————

use std/util null-device
use ../completion "into completions"

# ——— constants ——————————————————————————————————————————————————————————————

const COMMANDS: list<string> = [task project label section comment completed today upcoming inbox filter reminder activity stats auth accounts config help]

# ——— definitions —————————————————————————————————————————————————————————————

# Pass arguments to `td`; `--json` and `--ndjson` output is parsed.
@category productivity
export def --wrapped main [
  # nu-lint-ignore: missing_output_type
  ...rest: string@_td # Arguments for `td`
  --json (-j) # Request data in JSON and convert to Nushell types before returning
  --ndjson (-n) # Behaves the same as `--json`
  --long (-l) # Return all columns (only works with `--[nd]json`)
]: nothing -> oneof<nothing, string, table> {
  if $json or $ndjson {
    todoist --json ...$rest | if ($in | columns) has content { hydrate null --long=$long } else { }
  } else { run-external td ...$rest }
}

# Tasks as rows with the project name resolved and `due` as a datetime.
@category productivity
export def list [
  --project (-p): string@_projects # Project name (default: every project)
  --label (-l): list<string>@_labels # Only tasks carrying every one of these labels
  --parent: string@_tasks # Subtasks of this task (id or exact content)
  --filter (-f): string # Raw Todoist filter query
  --completed (-c) # Completed tasks instead of open ones
  --since: datetime # With `--completed`: lower bound (default: today; at most three months back)
]: nothing -> table<id: string, content: string, description: string, labels: list<string>, project: string, parent: oneof<nothing, string>, due: oneof<nothing, datetime>, priority: int, url: string> {
  if $completed {
    todoist --json --options={
      project: $project
      since: ($since | format-due)
    } completed list --all
  } else {
    todoist --json --options={
      project: $project
      parent: $parent
      filter: $filter
      label: ($label | join-labels)
    } task list --all
  } | hydrate $project
}

# One task as a row.
@category productivity
export def view [
  ref: string@_tasks # Task id, `id:<id>`, or exact content
]: nothing -> record { todoist --json task view $ref | hydrate null | first }

# Create a task; returns its row.
@category productivity
export def add [
  content: string # Task content
  --project (-p): string@_projects # Project name (default: Inbox)
  --description (-d): string # Task description
  --labels (-l): list<string>@_labels # Labels to attach
  --parent: string@_tasks # Parent task (id or exact content)
  --due: oneof<datetime, string> # Due date; a string passes through as the Todoist due string
  --priority: int # 1 (p1, urgent) to 4 (p4)
]: nothing -> record {
  todoist --json --options={
    project: $project
    description: $description
    labels: ($labels | join-labels)
    parent: $parent
    due: ($due | format-due)
    priority: ($priority | format-priority)
  } task add $content | hydrate $project | first
}

# Update fields of a task; returns its row.
@category productivity
export def edit [
  ref: string@_tasks # Task id, `id:<id>`, or exact content
  --content: string # New content
  --description (-d): string # New description
  --labels (-l): list<string>@_labels # Replacement label set
  --due: oneof<datetime, string> # New due date; a string passes through as the Todoist due string
  --no-due # Remove the due date
  --priority: int # 1 (p1, urgent) to 4 (p4)
]: nothing -> record {
  todoist --json --options={
    content: $content
    description: $description
    labels: ($labels | join-labels)
    due: ($due | format-due)
    priority: ($priority | format-priority)
    no_due: $no_due
  } task update $ref | hydrate null | first
}

# Complete tasks.
@category productivity
export def done [...refs: string@_tasks]: nothing -> nothing {
  for ref in $refs { todoist --auth task complete $ref }
}
# Reopen completed tasks.
@category productivity
export def reopen [...refs: string@_tasks]: nothing -> nothing {
  for ref in $refs { todoist --auth task uncomplete $ref }
}
# Delete tasks.
@category productivity
export def rm [...refs: string@_tasks]: nothing -> nothing {
  for ref in $refs { todoist --auth task delete $ref --yes }
}
# Open a task in the browser.
@category productivity
export def browse [ref: string@_tasks]: nothing -> nothing {
  todoist --auth task browse $ref | ignore
}
# Projects with their ids and urls.
@category productivity
export def projects []: nothing -> table<id: string, name: string, url: string> {
  todoist --json project list | select $.id? $.name? $.url?
}
# Labels with their ids.
@category productivity
export def labels []: nothing -> table<id: string, name: string> {
  todoist --json label list | select $.id? $.name?
}

# Best-effort match of a slug against candidate rows (pipeline input) or the project's open tasks.
#
# An exact content match scores 1. Otherwise the highest Jaccard overlap of the token sets (split on
# `-`, `/`, `@` and `.`) at or above the threshold wins; a tie for the top score yields null.
@category productivity
export def find [
  slug: string # Branch name or slug to match
  --project (-p): string@_projects # Project to search (default: basename of the repository root)
  --threshold: float = 0.5 # Minimum overlap for a fuzzy match
]: oneof<nothing, table> -> oneof<nothing, record<id: string, content: string, score: float, url: string>> {
  default { list --project ($project | default { repo-name }) }
  | insert score {|row| score $slug $row.content }
  | where score >= $threshold
  | sort-by --reverse score
  | let scored: table;
  match ($scored | length) {
    0 => null
    2.. if $scored.0?.score == $scored.1?.score => null
    _ => { $scored | first | select $.id? $.content? $.score? $.url? }
  }
}

# ——— helpers ————————————————————————————————————————————————————————————————

# Run `td` through the auth retry.
def --wrapped todoist [
  ...rest: string
  # Arguments to pass through to `td`
  --options: record = {}
  # Convert to options and add to arguments
  --json
  # Enables structured output
  --ndjson
  # Enables structured output
  --auth
  # Use the authentication guard
]: nothing -> oneof<string, table> {
  let struct: bool = $json or $ndjson
  $options
  | into options --fold=($rest | if $struct { append '--json' } else { })
  | if $auth or not $struct {
    use ../elevate with-auth
    with-auth --login={|| run-external td auth login } td ...$in
  } else {
    let args;
    use ../util attempt
    attempt --merge td ...$args | get $.stdout
  } | if $struct {
    from json | collect {|| if $in has results { get $.results } else { append [] } }
  } else { }
}

# Converts input record to flags with their values, or nothing when the value is `null` or `false`.
# Record values evaluating to `true` will have their values dropped but the flag itself kept.
# - If you want to pass `true` directly, set its option name to the string `'true'` instead.
def "into options" [
  --fold: list<oneof<nothing, string>> = []
  # Value-less flags; `null` items will be ignored
]: record -> list<string> {
  transpose name value
  | where value not-in [null false]
  | update name { if $in starts-with '--' { } else { $"--($in)" } }
  | update value { match ($in | describe) { bool => null _ => { into string } } }
  | reduce --fold=($fold | compact --empty) {|row| append [$row.name $row.value] | compact }
}

def join-labels []: oneof<nothing, list<string>> -> oneof<nothing, string> {
  if ($in | describe) == list<string> { str join , }
}

def format-due []: oneof<nothing, datetime, string> -> oneof<nothing, string> {
  match ($in | describe) { datetime => { format date %F } string => { } }
}

# App priority 1 (p1) to 4 (p4) as the `td` flag value.
def format-priority []: oneof<nothing, int> -> oneof<nothing, string> {
  match ($in | describe) { int => $'p($in)' }
}

def repo-name []: nothing -> string {
  use ../util attempt
  try { attempt --check git rev-parse --show-toplevel } catch {
    error make --unspanned 'not inside a repository: pass `--project`'
  } | str trim | path basename
}

def tokens []: string -> list<string> {
  str lowercase | split row --regex '[-/@.]+' | compact --empty | uniq
}

def score [slug: string content: string]: nothing -> float {
  if $slug == $content { return 1.0 }
  $slug | tokens | do {|b: list<string>|
    let both: int = $in | where $b has $it | length
    ($in | length) + ($b | length) - $both
    | if $in == 0 { 0 } else { $both / $in }
  } ($content | tokens)
  | into float
}

# Rows of `td` task JSON: project name (`$name` when given, otherwise resolved), `due` as a datetime, app priority.
def hydrate [name: oneof<nothing, string> --long = false]: table -> table {
  let rows: table = $in
  # one `td project list` call, and only when a name has to be resolved
  let projects: table = if $name == null and ($rows | is-not-empty) { projects } else { [] }
  $rows | if $long { } else {
    select $.id $.content $.description $.labels? $.projectId? $.parentId? $.due.date? $.priority $.url
  } | rename --column={projectId: project parentId: parent due.date: due}
  | default [] labels
  | update $.project {|row| $name | default { $projects | where id == $row.project | get $.0?.name } }
  | update $.priority { into int | 5 - $in }
  # `--long` keeps `due` as the raw record
  | if $long { } else { update $.due { if $in != null { into datetime } } }
}

# ——— completions —————————————————————————————————————————————————————————————

def _td [buffer: string]: nothing -> oneof<list, record> {
  let line: string = $buffer | str replace --regex '^\S+\s' 'td '
  $env.config.completions.external.completer? | if $in == null { [] } else { do $in $line }
  | default --empty { if ($line | split row --regex '\s+' | length) <= 2 { $COMMANDS } else { [] } }
}
def _projects []: nothing -> record {
  projects | select name url
  | rename value description
  | into completions {completion_algorithm: substring}
}
def _labels []: nothing -> record {
  labels | get name
  | into completions {completion_algorithm: substring}
}
def _tasks []: nothing -> record {
  list | select content project
  | rename value description
  | into completions {completion_algorithm: substring match_description: true}
}
