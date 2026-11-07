# Project discovery and catalog utilities.
#
# The registry is one snapshot in universal kv (table `proj`, key `snapshot`): the projects of every kind, the last
# scan's totals and a stamp (when it was taken, and a fingerprint of the workspace's kind directories). Readers
# never wait for a scan: an interactive shell refreshes a missing or stale snapshot in a background job at import
# (`_docs/hydration.md`), a non-interactive shell scans synchronously only when there is no snapshot at all, and
# `scan` always runs in the foreground and rewrites the snapshot in one write.

# nu-lint-ignore-file: string_param_as_path

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]
use hook with
use error
use log
use session
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

# A snapshot older than this is refreshed even when the kind directories look unchanged (remotes change inside them).
const TTL: duration = 24hr
# A `hydrating` mark younger than this means another shell's job is already refreshing the snapshot.
const HYDRATING: duration = 2min
# The description of the hydration job (`job list`).
const JOB: string = 'proj: scanning the workspace'

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-meta = kv set --universal --table=proj
alias get-meta = kv get --universal --table=proj
alias drop-meta = kv drop --universal --table=proj
alias list-meta = kv list --universal --table=proj
alias kind-to-table-name = do {|k: string| return $"proj_kind_($k | str trim)" }

# ——— environment ——————————————————————————————————————————————————————————————

# An interactive shell with a workspace refreshes a missing or stale snapshot in the background. Nothing else happens
# at import: a job would die with a non-interactive shell, whose readers scan on demand instead, and without
# `$env.WORK` there is nothing to scan (the commands that need the workspace raise an error naming the variable).
export-env {
  use std/dirs
  if (has-workspace) and $nu.is-interactive { hydrate }
}

# ——— type-aliases —————————————————————————————————————————————————————————————

type ScanMetadata = record<found: int, added: int, start: datetime, end: datetime, elapsed: string>
type ProjectInfo = record<name: string, path: string, repo: oneof<nothing, string>, vcs: oneof<nothing, string>, host: oneof<nothing, string>>
type KindSummary = record<name: string, root: directory, description: string, projects: list<ProjectInfo>>
# The registry: `kinds` maps each kind to its projects; `stamp.fingerprint` maps each kind to its directory's
# modification time (ns), null when the directory does not exist.
type Snapshot = record<stamp: record<at: datetime, fingerprint: record>, last_scan: ScanMetadata, kinds: record>

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
      error raise $"test fixture is inactive for kind '($kind)'" --with={
        kind: conflict
        help: 'run `test before` with the same kind first'
      }
    } else {
      # Hidden first: after a `def --env` call such as `kv drop`, `hide-env` no longer reaches the caller.
      hide-env project_testing
      for k in (kv list --universal --table=$t | get $.key) { kv drop --universal --table=$t $k | ignore }
    }
  }
}

# Scan the workspace for projects and rewrite the registry snapshot.
# ---
# Returns the scan metadata `{found added start end elapsed}` for the scanned kinds (the record of the last scan
# when its stamp matches the kind directories and is younger than 24 hours, unless `--force` or `--reset` is given). Registered projects are kept
# unless their directory is gone; new directories are inspected and added. `--prune` only drops the missing ones,
# prints how many and returns nothing. Scanning needs `$env.WORK` (the workspace root).
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
  # Scan even when the snapshot is fresh (its stamp matches the kind directories and is younger than the TTL)
  --prune (-p)
  # Only remove missing directories from the registry (no additions)
  --reset (-r)
  # Discard the registered projects of the scanned kinds first (all metadata when every kind is scanned)
]: nothing -> oneof<ScanMetadata, nothing> {
  if $prune { print $"removed (prune-missing-dirs) projects"; return }
  # The arguments and the workspace are checked before the TTL short-circuit: a fresh snapshot excuses neither.
  let unknown: list<string> = $kinds | where $KIND not-has $it
  if $unknown != [] {
    error raise $"unknown kind: '($unknown | first)'" --with={
      kind: invalid_argument
      help: $"kinds: ($KIND | columns | str join ', ')"
    }
  }
  let work: path = workspace
  let current: oneof<nothing, record> = snapshot
  if not ($reset or $force) and $current != null and not (is-stale $current) { return $current.last_scan }
  let scanned: list<string> = $KIND | columns | where $it in $kinds
  let full_reset: bool = $reset and ($KIND | columns | all $it in $kinds)
  let start: datetime = date now
  # The registered projects that stay: every kind's rows whose directory still exists; none for a kind being reset.
  let kept: record = $KIND | columns | each {|k|
    let rows: list<record> = if $reset and $k in $scanned { [] } else { $current | rows-of-snapshot $k }
    {$k: ($rows | where ($it.path | path exists))}
  } | into record
  let results: list<record> = $scanned | each {|k|
    let exclude: list<string> = $env.project_exclude!?
      | default {}
      | get --ignore-case --optional $k
      | default []
      | append '**/.*'
    # Collect only the immediate children, excluding tooling files
    glob --no-file --no-symlink ($work | path join $k *) --exclude=$exclude
    | intake-kind $k --known ($kept | get $k)
  }
  let kinds: record = $kept | merge ($results | each {|r| {($r.kind): $r.rows} } | into record) | apply-aliases
  let end: datetime = date now
  let last_scan: record = {
    found: ($results | each {|r| $r.found } | append 0 | math sum)
    added: ($results | each {|r| $r.added } | append 0 | math sum)
    start: $start
    end: $end
    elapsed: ($end - $start | format duration ms) # format for readability
  }
  {stamp: (stamp $work) last_scan: $last_scan kinds: $kinds pruned_at: (if $full_reset { null } else { $current.pruned_at? })}
  | record where value != null
  | write-snapshot
  # A full reset discards the old registry's other keys only after the new snapshot is in place: a scan that fails
  # or is killed before this point leaves the previous snapshot (and the hydration mark) untouched.
  if $full_reset {
    for key in (list-meta | get $.key | where $it not-in [snapshot hydrating]) { drop-meta $key | ignore }
  }
  $last_scan
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
      error raise $"unknown kind: '($kind)'" --with={
        kind: invalid_argument
        help: $"kinds: ($KIND | columns | str join ', ')"
      }
    }
    string => {
      name: $kind
      root: (workspace | path join $kind)
      description: ($KIND | get $kind)
      projects: (rows-of $kind | each {|p| $p | insert $.kind $kind })
    }
    nothing if not $all => {
      error raise 'a kind must be provided without `--all`' --kind invalid_argument
    }
    nothing => {
      let work: path = workspace
      let snap: oneof<nothing, record> = snapshot-for-reading
      $KIND | transpose name description
      | insert $.root {|row| $work | path join $row.name }
      | insert $.projects {|row| $snap | rows-of-snapshot $row.name }
    }
  }
}

# Display metadata related to projects and module commands.
#
# The counts per kind and in total, the last scan, the snapshot's `stamp` (with its `age`), whether a background
# scan is running (`hydrating`) and, after a prune, `pruned_at`. While the first scan of a workspace is still
# running there is only `hydrating`; without a workspace the record is empty.
export def meta [key?: string@_meta_keys]: nothing -> oneof<nothing, string, int, bool, datetime, duration, record, table> {
  let snap: oneof<nothing, record> = snapshot-for-reading
  if $snap == null {
    let bare: record = if (has-workspace) { {hydrating: (is-hydrating)} } else { {} }
    return (if $key == null { $bare } else { $bare | get --optional $key })
  }
  let counts: record = $KIND | columns | each {|k| {$"($k)_count": ($snap | rows-of-snapshot $k | length)} } | into record
  let all: record = $counts
    | insert $.total_count ($counts | values | math sum)
    | insert $.last_scan $snap.last_scan
    | insert $.stamp ($snap.stamp | insert $.age ((date now) - $snap.stamp.at))
    | insert $.hydrating (is-hydrating)
    | merge ($snap | select --optional $.pruned_at | record where value != null)
  if $key == null { $all } else { $all | get --optional $key }
}

# Every project directory configured under the workspace.
export def list [
  --kind (-k): string@_kinds
  # Scope the query to a specific kind of project
  --long (-l)
  # Include `$.kind` in the output record
]: nothing -> list<ProjectInfo> {
  let snap: oneof<nothing, record> = snapshot-for-reading
  $KIND | columns
  | each --flatten {|k| $snap | rows-of-snapshot $k | each {|p| $p | insert $.kind $k } }
  | if $env.project_testing!? != null { append (fixture-rows) } else { }
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
  # Scan for new projects first (`scan --force`: the import-time refresh already honours the TTL)
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

# Whether a Zellij session is named after the project (its name or its directory). `session list` handles the
# client's "no sessions" exit and a missing client.
def is-existing-session []: ProjectInfo -> bool {
  let proj: record;
  let sessions: list<string> = session list --short
  $sessions has $proj.name or $sessions has ($proj.path | path basename)
}

# ——— snapshot ——————————————————————————————————————————————————————————————————

# The stored snapshot, or null.
def snapshot []: nothing -> oneof<nothing, record> { get-meta snapshot }

# The snapshot a reader uses. A missing one is built synchronously in a non-interactive shell with a workspace
# (there is no job to wait for); an interactive shell leaves it to the import-time job and sees nothing yet.
def snapshot-for-reading []: nothing -> oneof<nothing, record> {
  snapshot | default {
    if (has-workspace) and not $nu.is-interactive { scan --force | ignore; snapshot } else { null }
  }
}

def write-snapshot []: record -> nothing {
  let snap: record;
  set-meta snapshot $snap | ignore
}

# A snapshot's rows of one kind (none for a null snapshot or an unknown kind).
def rows-of-snapshot [kind: string]: oneof<nothing, record> -> list<record> {
  if $in == null { [] } else { $in.kinds | get --optional $kind | default [] }
}

# The registered projects of a kind, from the snapshot a reader uses.
def rows-of [kind: string]: nothing -> list<record> { snapshot-for-reading | rows-of-snapshot $kind }

# The projects registered by the `test` fixture, with its kind.
def fixture-rows []: nothing -> list<record> {
  let kind: string = $env.project_testing.kind
  kv list --universal --table=$env.project_testing.table | get $.value? | compact | each {|p| $p | insert $.kind $kind }
}

# The stamp of a snapshot taken now: when, and the fingerprint of the kind directories.
def stamp [work: path]: nothing -> record { {at: (date now) fingerprint: (fingerprint $work)} }

# The modification time (ns) of each kind directory: it changes when a project directory is added or removed.
def fingerprint [work: path]: nothing -> record {
  $KIND | columns | each {|k|
    let dir: path = $work | path join $k
    {$k: (if ($dir | path exists) { ls --directory $dir | get $.0.modified | into int } else { null })}
  } | into record
}

# Whether a snapshot is older than the TTL or was taken from a different workspace layout.
def is-stale [snap: record]: nothing -> bool {
  (date now) - $snap.stamp.at > $TTL or $snap.stamp.fingerprint != (fingerprint $env.work!)
}

# Whether a hydration job is running: this shell's, or another shell's (a fresh `hydrating` mark).
def is-hydrating []: nothing -> bool {
  (job list | any description? == $JOB) or (get-meta hydrating | if $in == null { false } else { (date now) - $in < $HYDRATING })
}

# Refresh a missing or stale snapshot in a background job, unless another shell is already at it. The job is
# disposable (`--auto-kill`: the snapshot write is atomic, so a killed job leaves the previous snapshot in place) and
# logs a failure once instead of raising into the prompt.
def hydrate []: nothing -> nothing { # nu-lint-ignore: unused_helper_functions
  let snap: oneof<nothing, record> = snapshot
  if $snap != null and not (is-stale $snap) { return }
  let mark: oneof<nothing, datetime> = get-meta hydrating
  if $mark != null and (date now) - $mark < $HYDRATING { return }
  set-meta hydrating (date now) | ignore
  # Past the TTL every registered project is inspected again (a remote changes inside an unchanged directory); a
  # changed layout only needs the new directories inspected and the missing ones dropped.
  let expired: bool = $snap == null or (date now) - $snap.stamp.at > $TTL
  job spawn --auto-kill --description $JOB {||
    try { scan --force --reset=$expired | ignore } catch {|e| log warning $"proj: the background scan failed: ($e.msg)" }
    drop-meta hydrating | ignore
  } | ignore
}

# Rename the projects whose directory has an alias in `$env.project_aliases!` (by absolute path first, then by
# directory name, as on intake); a project already registered under the alias name wins.
def apply-aliases []: record -> record {
  let kinds: record;
  let map: record = $env.project_aliases!? | default {}
  if $map == {} { return $kinds }
  $kinds | record each {|kind rows|
    let named: list<record> = $rows | each {|r| $r | insert $.alias ($map | alias-for $r.path | default $r.name) }
    let kept: list<record> = $named | where alias == $it.name | each {|r| $r | reject $.alias }
    let moved: list<record> = $named
      | where alias != $it.name and alias not-in ($kept | each {|r| $r.name })
      | each {|r| $r | update $.name $r.alias | reject $.alias }
    {$kind: ($kept | append $moved)}
  }
}

# The alias configured for a project directory in the input map: by absolute path first, then by name.
def alias-for [root: path]: record -> oneof<nothing, string> {
  get --ignore-case --optional $root ($root | path basename) | compact | first
}

# The kind's projects after registering the directories not registered yet (`known` rows are kept).
# Only the repository inspection (`git`) runs in parallel: each new root costs two child processes.
def intake-kind [
  kind: string # The kind being scanned
  --known: list<record> = [] # Its registered projects, kept as they are
]: list<path> -> record<kind: string, rows: list<record>, found: int, added: int> {
  let roots: list<path>;
  let map: record = $env.project_aliases!? | default {}
  let names: list<string> = $known | each {|r| $r.name }
  let new: list<record> = $roots
    | each {|root| {root: $root name: ($map | alias-for $root | default ($root | path basename))} }
    # Skip projects already registered to avoid duplicate entries
    | where name not-in $names
    | par-each --keep-order {|it| inspect $it.root $it.name }
  {kind: $kind rows: ($known | append $new) found: ($roots | length) added: ($new | length)}
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

# Drop the registered projects whose directory is gone; returns how many were dropped.
def prune-missing-dirs []: nothing -> int {
  let snap: record = snapshot
    | default {
      error raise 'no metadata found' --with={
        kind: not_found
        help: 'run a scan first'
      }
    }
  let kinds: record = $snap.kinds | record each {|k rows| {$k: ($rows | where ($it.path | path exists))} }
  let removed: int = ($snap.kinds | count) - ($kinds | count)
  # The stamp stays: it names the directory state the rows were computed from, and nothing was inspected here.
  $snap | update $.kinds $kinds | upsert $.pruned_at (date now) | write-snapshot
  $removed
}

# The number of projects in a kinds record.
def count []: record -> int { values | each { length } | append 0 | math sum }

# Whether `$env.WORK` (any case) names a workspace.
def has-workspace []: nothing -> bool { $env.work!? | is-not-empty }

# The workspace root, `$env.WORK`; raises an error naming the variable when it is unset or empty.
def workspace []: nothing -> path {
  if not (has-workspace) {
    error raise 'WORK is not set' --with={
      kind: missing_dependency
      help: 'set $env.WORK to the workspace root (the directory that holds src, txt, dev and ext)'
    }
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
def _meta_keys []: nothing -> list {
  [src_count txt_count dev_count ext_count total_count last_scan stamp hydrating pruned_at]
}
