# Project discovery and catalog utilities.

# nu-lint-ignore-file: string_param_as_path

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]
use hook with
use error
use style

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
  # [scheme://][user@]host[.domain][:port](:|/)owner/name[.git][/]; `host` is the first DNS label
  remote: '^(?:[a-z+]+://)?(?:[^@/]+@)?(?<host>[^/:.]+)(?:\.[^/:]+)?(?::\d+)?[:/](?<repo>[^/]+/[^/]+?)(?:\.git)?/?$'
}

const TTL: duration = 24hr

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-meta = kv set --universal --table=proj
alias get-meta = kv get --universal --table=proj
alias drop-meta = kv drop --universal --table=proj
alias list-meta = kv list --universal --table=proj
alias kind-to-table-name = do {|k: string| return $"proj_kind_($k | str trim)" }

# ——— environment ——————————————————————————————————————————————————————————————

# Automatically perform a scan when the module is used.
# Without `$env.WORK` there is no workspace to scan, so the scan is skipped: importing the module never fails,
# and the commands that need the workspace raise an error naming the variable instead.
export-env {
  use std/dirs
  if (has-workspace) { scan | ignore }
}

# ——— type-aliases —————————————————————————————————————————————————————————————

type ScanMetadata = record<found: int, added: int, start: datetime, end: datetime, elapsed: string>
type ProjectInfo = record<name: string, path: string, repo: oneof<nothing, string>, vcs: oneof<nothing, string>, host: oneof<nothing, string>>
type KindSummary = record<name: string, root: directory, description: string, projects: list<ProjectInfo>>


# ——— definitions ——————————————————————————————————————————————————————————————

# Fixture for suites of modules that read the registry: `use proj [test]`, then `test before`/`test after`.
export module test {
  export-env { if $env has project_testing { hide-env project_testing } }

  # Fixture for tests that depend on `proj` for project registration
  @category fixture
  export def --env before [kind: string = 'test']: list<ProjectInfo> -> nothing {
    let t: string = kind-to-table-name $kind
    $env.project_testing = {kind: $kind table: $t}
    for proj in $in { kv set --universal --table=$t $proj.name $proj | ignore }
  }

  # Cleanup fixture for projects registered with `test before`.
  @category fixture
  export def --env after [kind: string = 'test']: nothing -> nothing {
    let t: string = kind-to-table-name $kind
    if $env not-has project_testing or $env.project_testing!? != {kind: $kind table: $t} {
      error raise $"project test fixture is inactive for kind: '($kind)'" --kind conflict --advice 'run `test before` with the same kind first'
    } else {
      # Hidden first: after a `def --env` call such as `kv drop`, `hide-env` no longer reaches the caller.
      hide-env project_testing
      for k in (kv list --universal --table=$t | get $.key) { kv drop --universal --table=$t $k | ignore }
    }
  }
}

# Scan for repositories for each kind and initialize their data tables.
# ---
# Returns the scan metadata `{found added start end elapsed}` for the scanned kinds (the cached record of the
# last scan when it is younger than 24 hours and neither `--force` nor `--reset` is given); `--prune` prints the
# number of removed projects and returns nothing. Scanning needs `$env.WORK` (the workspace root).
# Notes:
# - Projects can be saved under custom names with `$env.project_aliases!`
#   - Entries map a dirname or absolute path (key) to the preferred name (value)
# - Directories can be excluded per kind with glob patterns in `$env.project_exclude!` (e.g. `{src: ['**/tmp*']}`)
@category productivity
@example 'scan for projects' { proj scan }
@example 'scan for projects with aliased names' { with-env {project_aliases: {foo: bar abc: xyz}} { proj scan } }
export def scan [
  --kinds (-k): list<string>@_kinds = [src dev txt ext]
  # Only operate on a subset of kinds
  --force (-f)
  # Bypass the TTL and search only for new projects
  --prune (-p)
  # Only remove missing directories from the registry (no additions)
  --reset (-r)
  # Clear the existing data of the scanned kinds (all metadata when every kind is scanned) prior to scanning
]: nothing -> oneof<ScanMetadata, nothing> {
  drop-meta flat_list # drop cached list whenever scan runs in case of changes
  if $prune { prune-missing-dirs | return }
  if not ($reset or $force) {
    get-meta last_scan
    | if $in != null and (date now) - $in.start < $TTL { return $in }
  }
  let unknown: list<string> = $kinds | where {|k| $KIND not-has $k }
  if $unknown != [] {
    error raise $"unknown kind: '($unknown | first)'" --kind invalid_argument --advice $"kinds: ($KIND | columns | str join ', ')"
  }
  let work: path = workspace
  let scanned: list<string> = $KIND | columns | where $it in $kinds
  if $reset { reset-meta ...$scanned }
  let start: datetime = date now
  # Sequential: concurrent `kv` writers contend for SQLite's lock (and can leave placeholder rows behind).
  $scanned | each {|k|
    let table: string = kind-to-table-name $k
    let exclude: list<string> = $env.project_exclude!?
      | default {}
      | get --ignore-case --optional $k
      | default []
      | append '**/.*'
    if $reset { reset-table $table }
    # Collect only the immediate children, excluding tooling files
    glob --no-file --no-symlink ($work | path join $k *) --exclude=$exclude
    | intake-kind --reset=$reset $k $table
  } | record-scan-metadata $start
}

# Show descriptions and registrations for one or more `kind`s of projects.
export def kind [
  kind?: string@_kinds
  # Return the description and projects registered for a single kind
  --all (-a)
  # Return descriptions and registered projects for all kinds
]: nothing -> oneof<KindSummary, list<KindSummary>, error> {
  match ($kind | describe) {
    string if $KIND not-has $kind => {
      error raise $"unknown kind: '($kind)'" --kind invalid_argument --advice $"kinds: ($KIND | columns | str join ', ')"
    }
    string => {
      name: $kind
      root: (workspace | path join $kind)
      description: ($KIND | get $kind)
      projects: (list-kind --insert=true $kind)
    }
    nothing if not $all => { error raise 'a kind must be provided without `--all`' --kind invalid_argument }
    nothing => (
      $KIND | transpose name description
      | insert $.root {|row| workspace | path join $row.name }
      | insert $.projects {|row| list-kind --insert=false $row.name }
    )
  }
}

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
]: nothing -> list<ProjectInfo> {
  get-meta flat_list | default {||
    set-meta --return=value flat_list (
      $KIND | columns | each {|k| list-kind --insert=true $k } | flatten
    )
  } | if $env.project_testing!? != null {
    append (list-kind --insert=true $env.project_testing.kind)
  } else { }
  | if $kind == null { } else { where kind == $kind }
  | if $long { } else { reject $.kind }
}

# Pick a project.
# If only one project matches the query it is chosen, otherwise a fuzzy picker opens. The chosen project is
# pushed with `dirs add` (unless it is the current directory), or used for `--exec`/`--boot`.
@example 'choose from all projects' { proj }
@example 'jump straight to a unique match' { proj daisy-th }
@category productivity
export def --env main [
  query?: string@_names
  # Regex to filter directories
  --kind (-k): string@_kinds
  # Scope the query to a specific kind of project
  --scan (-s)
  # Scan for new projects first (`scan --force`: the import-time scan already honours the TTL)
  --boot (-b)
  # Enter a `zellij` session for the project (creating if not existing)
  --exec (-x): closure
  # Run a closure from the project root (with the `zellij::pwd::auto-switch` hook disabled, if registered)
]: nothing -> oneof<nothing, any> {
  if $scan { scan --force | ignore }
  list --kind=$kind --long
  | match ($query | describe) { nothing => () string => { where name =~ $query } }
  | match ($in | length) {
    # the arm receives the match input (the table), which `error raise` does not take: hence `null |`
    0 => { null | error raise $"no project matches '($query)'" --kind not_found }
    1 => (first)
    _ => (input list --fuzzy --display={|it| display-label $it })
  } | if $in == null { return } else {
    let proj: ProjectInfo;
    if $exec != null {
      do --capture-errors {
        with --name=zellij::pwd::auto-switch --root=$proj.path {disabled: true} $exec
      }
    } else if $boot {
      $proj | if not ($in | is-existing-session) {
        create-session-in-project
      }
      if $env has ZELLIJ {
        ^zellij action switch-session $proj.name
      } else {
        ^zellij attach $proj.name
      }
    } else if $proj.path != $env.pwd! {
      try {
        use std/dirs add
        add $proj.path
      } catch {
        cd $proj.path
      }
    }
  }
}

# ——— helpers ———————————————————————————————————————————————————————————————————
def create-session-in-project []: record -> nothing {
  cd $in.path
  ^zellij attach --create-background $in.name options --default-cwd $in.path
}


def is-existing-session []: ProjectInfo -> bool {
  let proj: record;
  let sessions: list<string> = zellij list-sessions --short --no-formatting | lines | str trim
  $sessions has $proj.name or $sessions has ($proj.path | path basename)
}

# Rename registered projects whose directory has an alias in `$env.project_aliases!` (see `scan`).
# Aliases match by absolute path first, then by directory name, exactly as on intake.
def deduplicate []: nothing -> nothing {
  let map: record = $env.project_aliases!? | default {}
  if $map == {} { return }
  for kind in ($KIND | columns) {
    let t: string = kind-to-table-name $kind
    let q: list<record> = kv list --universal --table=$t
      | get $.value?
      | compact
      | each {|it| {name: $it.name alias: ($map | alias-for $it.path)} }
      | where alias != null and name != alias
    for row in $q {
      kv drop --universal --table=$t $row.name
      | if (kv get --universal --table=$t $row.alias) == null {
        update $.name $row.alias | kv set --universal --table=$t $row.alias
      }
    }
  }
}

# The alias configured for a project directory in the input map: by absolute path first, then by name.
def alias-for [root: path]: record -> oneof<nothing, string> {
  get --ignore-case --optional $root ($root | path basename) | compact | first
}

# Register the kind's directories that are not registered yet (all of them with `--reset`).
# Only the repository inspection (`git`) runs in parallel; the `kv` reads and writes do not.
def intake-kind [kind: string table: string --reset]: list<path> -> record<found: int, added: int> {
  let roots: list<path> = $in
  let map: record = $env.project_aliases!? | default {}
  let known: list<string> = if $reset { [] } else { kv list --universal --table=$table | get $.key? | default [] }
  let rows: list<record> = $roots
    | each {|root| {root: $root name: ($map | alias-for $root | default ($root | path basename))} }
    # Skip projects already registered to avoid duplicate entries
    | where name not-in $known
    | par-each {|it| inspect $it.root $it.name }
  # Register the repositories in the kind-scoped `kv` store.
  for row in $rows { kv set --universal --table=$table $row.name $row | ignore }
  {found: ($roots | length) added: ($rows | length)}
  | set-meta --return=input $'($kind)_count' $in.found
}

# The registry record of a project directory: git remote information when it is a repository.
def inspect [root: path name: string]: nothing -> record {
  let base: string = $root | path basename
  if ($root | path join '.git' | path exists) {
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
      | match $in { '' => ({}) $u => {repo: $'($u)/($base)'} }
    ) | insert $.vcs git
  } | default {}
  # Default here to ensure columns exist
  | default null $.repo? $.vcs? $.host?
  # Rebuild the record with static values and reordered columns
  | {name: $name path: $root ...$in}
}

# Apply aliases, then store the totals of the scanned kinds as `last_scan`; `total_count` covers every kind.
def record-scan-metadata [
  start: datetime
]: list<record<found: int, added: int>> -> record {
  let totals: record = reduce --fold {found: 0 added: 0} {|it acc|
    {found: ($acc.found + $it.found) added: ($acc.added + $it.added)}
  }
  deduplicate
  let end: datetime = date now
  let counts: list<string> = $KIND | columns | each { $'($in)_count' }
  list-meta | where key in $counts | reduce --fold 0 {|it acc| $acc + $it.value } | set-meta total_count
  set-meta --return=value last_scan {
    ...$totals
    start: $start
    end: $end
    elapsed: ($end - $start | format duration ms) # format for readability
  }
}

def prune-missing-dirs []: nothing -> nothing {
  let total: int = get-meta total_count
    | default { error raise 'no metadata found' --kind not_found --advice 'run a scan first' }
  $KIND | columns | each {|k|
    let table: string = kind-to-table-name $k
    # Rows without a value are placeholders that concurrent `kv` writers can leave behind, not projects.
    let queue: list<record> = kv list --universal --table=$table | where value != null
    let missing: list<string> = $queue | where not ($it.value.path | path exists) | get $.key
    for key in $missing { kv drop --universal --table=$table $key | ignore }
    set-meta --return=value $"($k)_count" (($queue | length) - ($missing | length))
  } | math sum
  | set-meta --return=input total_count
  | print $"removed ($total - $in) projects"
  date now | set-meta pruned_at
}

def list-kind [kind: string --insert = true]: nothing -> list<ProjectInfo> {
  let table: string = kind-to-table-name $kind
  kv list --universal --table=$table
  | get $.value?
  | compact
  | if $insert { insert $.kind $kind } else { }
}

def reset-table [table: string]: nothing -> nothing {
  for key in (kv list --universal --table=$table).key {
    kv drop --universal --table=$table $key
  }
}

# Clear the metadata of the given kinds (counts and labels); all metadata when every kind is given.
def reset-meta [...kinds: string]: nothing -> nothing {
  if ($KIND | columns | all {|k| $k in $kinds }) { reset-table proj; return }
  for key in (list-meta | get $.key) {
    if ($kinds | any {|k| $key == $'($k)_count' or ($key | str starts-with $'($k)(char psep)') }) {
      drop-meta $key | ignore
    }
  }
}

# Whether `$env.WORK` (any case) names a workspace.
def has-workspace []: nothing -> bool { $env.work!? | is-not-empty }

# The workspace root, `$env.WORK`; raises an error naming the variable when it is unset or empty.
def workspace []: nothing -> path {
  if not (has-workspace) {
    error raise 'WORK is not set' --kind missing_dependency --advice 'set $env.WORK to the workspace root (the directory that holds src, txt, dev and ext)'
  }
  $env.work!
}

# The picker label of a project, `kind/name` in the kind's colour. Not cached: a styled label stored in kv would be
# wrong whenever the colour setting differs from the one it was first computed under (and a kv read costs more).
def display-label [it: record<name: string, kind: string>]: nothing -> string {
  $it | format pattern $'{kind}(char psep){name}' | style paint ($COLOR | get $it.kind)
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
