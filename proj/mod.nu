# Project discovery and catalog utilities.

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]

# ——— constants ————————————————————————————————————————————————————————————————

const KIND: record = {
  src: 'projects containing mostly source code'
  txt: 'projects containing mostly prose'
  dev: 'projects scoped to the development environment'
  ext: 'projects containing vendored code and/or integrations with outside tools'
}

const COLOR: record = {
  src: blue
  txt: green
  dev: magenta
  ext: yellow
}

const RE: record = {
  remote: '^(?:[a-z+]+://)?(?:[^@/]+@)?(?<host>[^/:.]+)(?:\.[^/:]+)?[:/](?<repo>[^/]+/[^/]+?)(?:\.git)?/?$'
}

const TTL: duration = 24hr

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-meta = kv set --universal --table=proj
alias get-meta = kv get --universal --table=proj
alias drop-meta = kv drop --universal --table=proj
alias list-meta = kv list --universal --table=proj
alias glob-proj = glob --no-file --no-symlink --exclude=[**/.*]
alias kind-to-table-name = do {|k: string| return $"proj_kind_($k | str trim)" }

# ——— environment ——————————————————————————————————————————————————————————————

# Automatically perform a scan when the module is used
export-env { use std/dirs; scan }

# ——— definitions ——————————————————————————————————————————————————————————————

# Scan for repositories for each kind and initialize their data tables.
# ---
# Notes:
# - Projects can be saved under custom names with `$env.project_aliases!`
#   - Each entry should map a directory name (key) to the prerred name (value)
@category productivity
@example 'scan for projects' { proj scan }
@example 'scan for projects with aliased names' { with-env {project_aliases: {foo: bar abc: xyz}} { proj scan } }
export def scan [
  --force (-f) # Bypass the TTL and search only for new projects
  --prune (-p) # Only remove missing directories from the registry (no additions)
  --reset (-r) # Clear all existing project data (including metadata) prior to scanning
]: nothing -> oneof<nothing, record<found: int, added: int, start: datetime, end: datetime, elapsed: string>> {
  if $prune { prune-missing-dirs | return }
  if not ($reset or $force) {
    get-meta last_scan
    | if $in != null and (date now) - $in.start < $TTL { return $in }
  }
  if $reset { reset-table proj }
  let start: datetime = date now
  $KIND | columns | par-each {|k|
    let table: string = kind-to-table-name $k
    # Run synchronously so we're not deleting new additions
    if $reset { reset-table $table }
    # Collect only the immediate children, exluding tooling files
    glob-proj ($env.work! | path join $k *)
    | intake-kind --reset=$reset $k $table
  } | record-scan-metadata $start
}

# Show descriptions for each `kind` of project.
export alias kind = echo $KIND

# Display metadata related to projects and module commands.
export def meta [key?: string@_meta_keys]: nothing -> oneof<string, int, datetime, record, table> {
  if $key != null { return (get-meta $key) }
  list-meta | if $in == [] {
    return {}
  } else {
    transpose --ignore-titles --header-row --as-record
  }
}

# Every project directory configured under the workspace.
export def list [
  --kind (-k): string@_kinds
  # Scope the query to a specific kind of project
  --long (-l)
  # Include `$.kind` in the output record
]: nothing -> table<name: string, path: directory> {
  if $kind != null {
    list-kind $kind --insert=$long
  } else {
    $KIND | columns | par-each {|k| list-kind --insert=$long $k } | flatten
  }
}

# Pick a project.
# If only one project matches the query, it will be pushed with `dirs add`.
@example 'choose from all projects' { proj }
@example 'jump straight to a unique match' { proj daisy-th }
@category productivity
export def --env main [
  query?: string@_names
  # Regex to filter directories
  --kind (-k): string@_kinds
  # Scope the query to a specific kind of project
  --scan (-s)
  # Run the repository scan before querying project data
  --boot (-b)
  # Enter a `zellij` session for the project (creating if not existing)
]: nothing -> nothing {
  if $scan { scan }
  list --kind=$kind --long
  | match ($query | describe) { nothing => () string => { where name =~ $query } }
  | match ($in | length) {
    0 => { error make --unspanned $"no project matches '($query)'" }
    1 => (first)
    _ => (input list --fuzzy --display={|it| display-label $it })
  } | if $in == null {
    return
  } else if $boot {
    if $env has ZELLIJ {
      ^zellij attach --create-background $in.name options --default-cwd $in.path
      ^zellij action switch-session $in.name
    } else {
      ^zellij attach --create $in.name options --default-cwd $in.path
    }
  } else if $in.path != $env.pwd! {
    let p: path = $in.path
    try { use std/dirs add; add $p } catch { cd $p }
  }
}

# ——— helpers ———————————————————————————————————————————————————————————————————

def intake-kind [kind: string table: string --reset]: list<path> -> record<found: int, added: int> {
  let map: record = $env.project_aliases!? | default {}
  $in | par-each {|root|
    let name: string = $root
      | path basename
      | if $map has $in { let key: string; $map | get $key } else { }
    if not $reset and (kv get --universal --table=$table $name) != null {
      # Skip projects already registered to avoid duplicate entries
      return false
    } else if ($root | path join '.git' | path exists) {
      # Projects with source-control - collect repository information
      ^git -C $root config remote.origin.url
      | ignore --stderr
      | if ($in | is-not-empty) {
        # If it exists, parse repository name, owner, and type (remote domain)
        parse --regex $RE.remote | first
        # Ensure unmatched URLs fallthrough to no-remote arm
      } | default (
        # Else, populate from available data
        ^git -C $root config user.name
        | ignore --stderr
        | match $in { '' => ({}) $u => {repo: $'($u)/($name)'} }
      ) | insert $.vcs git
    } | default {}
    # Select as optional cell paths to automatically populate `null` fill values
    | select $.repo? $.vcs? $.host?
    # Rebuild the record with static values and reordered columns
    | {name: $name path: $root ...$in}
    # Register the repository in the kind-scoped `kv` store.
    | kv set --universal --table=$table $name
    return true
  } | {found: ($in | length) added: ($in | where $it | length)}
  | set-meta --return=input $'($kind)_count' $in.found
}

def record-scan-metadata [
  start: datetime
]: table<found: int, added: int> -> record<found: int, added: int, start: datetime, end: datetime, elapsed: string> {
  let totals: record = math sum
  let end: datetime = date now
  $totals | set-meta --return=input total_count $in.found
  | set-meta --return=value last_scan {
    ...$in
    start: $start
    end: $end
    elapsed: ($end - $start | format duration ms) # format for readability
  }
}

def prune-missing-dirs []: nothing -> nothing {
  let total: int = get-meta total_count
    | default { error make --unspanned {msg: 'no metadata found' help: 'run a scan first'} }
  $KIND | columns | par-each {|k|
    let table: string = kind-to-table-name $k
    let label: string = $"($k)_count"
    let queue: table = kv list --universal --table=$table
    let count: int = $queue | length
    let remaining: int = $queue
      | where not ($it.value.path | path exists) # keep missing
      | get $.key # unwrap keys
      | par-each { kv drop --universal --table=$table $in }
      | compact # only count non-`null` dropped values
      | $count - ($in | length)
    set-meta --return=value $label $remaining
  } | math sum
  | set-meta --return=input total_count
  | print $"removed ($total - $in) projects"
  date now | set-meta pruned_at
}

def list-kind [kind: string --insert = true]: nothing -> table {
  let table: string = kind-to-table-name $kind
  kv list --universal --table=$table
  | get $.value
  | if $insert { insert $.kind $kind } else { }
}

def reset-table [table: string]: nothing -> nothing {
  for key in (kv list --universal --table=$table).key {
    kv drop --universal --table=$table $key
  }
}

def display-label [it: record<name: string, kind: string>]: nothing -> string {
  let base: string = $it | format pattern $'{kind}(char psep){name}'
  let key: string = $base + '-label'
  get-meta $key
  | default (set-meta --return=value $key $'(ansi ($COLOR | get $it.kind))($base)(ansi rst)')
}

# ——— completions ——————————————————————————————————————————————————————————————

def _kinds []: nothing -> table { $KIND | transpose value description }
def _names []: nothing -> record {
  {
    options: {
      case_sensitive: false
      completion_algorithm: substring
      match_description: true
    }
    completions: (list | select $.name $.path | rename --column={name: value path: description})
  }
}
def _meta_keys []: nothing -> list { list-meta | get $.key }
