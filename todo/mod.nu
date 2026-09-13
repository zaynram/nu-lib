# Todoist tasks with the `td` CLI: typed rows, completions, slug matching and an auth retry.

use ../util ["into completions" with-auth]

# ——— constants ——————————————————————————————————————————————————————————————

const COMMANDS: list<string> = [task project label section comment completed today upcoming inbox filter reminder activity stats auth accounts config help]

# ——— definitions —————————————————————————————————————————————————————————————

# Pass arguments to `td`; `--json` and `--ndjson` output is parsed.
@category productivity
export def --wrapped main [ # nu-lint-ignore: missing_output_type
  ...rest: string@_td # Arguments for `td`
]: nothing -> any {
  td ...$rest | match ($rest | where $it in ['--json' '--ndjson'] | get --optional 0) {
    '--json' => { from json }
    '--ndjson' => { lines | each { from json } }
    _ => { }
  }
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
    td completed list --all --json ...(opt '--project' $project) ...(opt '--since' ($since | format-due))
  } else {
    td task list --all --json ...(opt '--project' $project) ...(opt '--parent' $parent) ...(opt '--filter' $filter) ...(opt '--label' ($label | join-labels))
  } | from json | get results | hydrate $project
}

# One task as a row.
@category productivity
export def view [
  ref: string@_tasks # Task id, `id:<id>`, or exact content
]: nothing -> record { td task view $ref --json | from json | [$in] | hydrate null | first }

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
  td task add $content --json ...(opt '--project' $project) ...(opt '--description' $description) ...(opt '--labels' ($labels | join-labels)) ...(opt '--parent' $parent) ...(opt '--due' ($due | format-due)) ...(opt '--priority' ($priority | format-priority))
  | from json | [$in] | hydrate $project | first
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
  td task update $ref --json ...(opt '--content' $content) ...(opt '--description' $description) ...(opt '--labels' ($labels | join-labels)) ...(opt '--due' ($due | format-due)) ...(if $no_due { ['--no-due'] } else { [] }) ...(opt '--priority' ($priority | format-priority))
  | from json | [$in] | hydrate null | first
}

# Complete tasks.
@category productivity
export def done [...refs: string@_tasks]: nothing -> nothing { for ref in $refs { td task complete $ref | ignore } }
# Reopen completed tasks.
@category productivity
export def reopen [...refs: string@_tasks]: nothing -> nothing { for ref in $refs { td task uncomplete $ref | ignore } }
# Delete tasks.
@category productivity
export def rm [...refs: string@_tasks]: nothing -> nothing { for ref in $refs { td task delete $ref --yes | ignore } }
# Open a task in the browser.
@category productivity
export def browse [ref: string@_tasks]: nothing -> nothing { td task browse $ref | ignore }
# Projects with their ids and urls.
@category productivity
export def projects []: nothing -> table<id: string, name: string, url: string> { td project list --json | from json | get results | select id name url }
# Labels with their ids.
@category productivity
export def labels []: nothing -> table<id: string, name: string> { td label list --json | from json | get results | select id name }

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
  | if ($in | is-empty) or (($in | length) > 1 and $in.0.score == $in.1.score) { null } else {
    first | select --optional id content score url
  }
}

# ——— helpers ————————————————————————————————————————————————————————————————

# Run `td` through the auth retry.
def --wrapped td [...args: string]: nothing -> string { with-auth --login {|| ^td auth login } td ...$args }

# A flag with its value, or nothing when the value is null.
def opt [flag: string value: oneof<nothing, string, int>]: nothing -> list<string> { if $value == null { [] } else { [$flag ($value | into string)] } }
def join-labels []: oneof<nothing, list<string>> -> oneof<nothing, string> { if ($in | is-empty) { null } else { str join ',' } }
def format-due []: oneof<nothing, datetime, string> -> oneof<nothing, string> { if ($in | describe) == datetime { format date %F } else { } }
# App priority 1 (p1) to 4 (p4) as the `td` flag value.
def format-priority []: oneof<nothing, int> -> oneof<nothing, string> { if $in == null { null } else { $'p($in)' } }
def repo-name []: nothing -> string {
  ^git rev-parse --show-toplevel | complete
  | if $in.exit_code == 0 { $in.stdout | str trim | path basename } else { error make --unspanned 'not inside a repository: pass `--project`' }
}
def tokens []: string -> list<string> { str lowercase | split row --regex '[-/@.]+' | where $it != '' | uniq }
def score [slug: string content: string]: nothing -> float {
  if $slug == $content { return 1.0 }
  let a: list<string> = $slug | tokens
  let b: list<string> = $content | tokens
  let both: int = $a | where $it in $b | length
  let union: int = ($a | length) + ($b | length) - $both
  if $union == 0 { 0.0 } else { $both / $union | into float }
}

# Rows of `td` task JSON: project name (`$name` when given, otherwise resolved), `due` as a datetime, app priority.
def hydrate [name: oneof<nothing, string>]: list -> table {
  let rows: list = $in
  let names: record = if $name != null or ($rows | is-empty) { {} } else { projects | each {|p| {$p.id: $p.name} } | into record }
  $rows | each {|row|
    {
      id: $row.id
      content: $row.content
      description: $row.description
      labels: ($row.labels? | default [])
      project: ($name | default ($names | get --optional $row.projectId))
      parent: $row.parentId?
      due: ($row.due?.date? | if $in == null { } else { into datetime })
      priority: (5 - $row.priority)
      url: $row.url
    }
  }
}

# ——— completions —————————————————————————————————————————————————————————————

def _td [buffer: string]: nothing -> oneof<list, record> {
  let line: string = $buffer | str replace --regex '^\S+\s' 'td '
  $env.config.completions.external.completer? | if $in == null { [] } else { do $in $line }
  | default --empty { if ($line | split row --regex '\s+' | length) <= 2 { $COMMANDS } else { [] } }
}
def _projects []: nothing -> record { projects | select name url | rename value description | into completions {completion_algorithm: substring} }
def _labels []: nothing -> record { labels | get name | into completions {completion_algorithm: substring} }
def _tasks []: nothing -> record { list | select content project | rename value description | into completions {completion_algorithm: substring, match_description: true} }
