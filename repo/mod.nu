# Repository aggregation utilities and resolvers (GitHub-only for now).

# TODO: remove this module after replacing all references with `proj`/`work`/`todo` methods

use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]
use ../path

# ——— constants ————————————————————————————————————————————————————————————————

const COLS: list<string> = [
  name
  state
  branch
  remote
  tag
  path
  ahead
  behind
  ignored
  conflicts
  stashes
]

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-repo = kv set --universal --table=repositories
alias get-repo = kv get --universal --table=repositories
alias drop-repo = kv drop --universal --table=repositories
alias list-repo = kv list --universal --table=repositories

def repo-snapshot []: nothing -> record {
  list-repo | default --empty {
    set-repo discovery {enabled: false root: $nu.home-dir}
    set-repo path []
    set-repo hidden ['**/.*/**']
    set-repo cache ($nu.cache-dir | path join repositories.nuon)
    list-repo
  } | transpose --ignore-titles --header-row --as-record
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Initialize the `repo` module data using `kv [get|set|drop|list] --universal --table=repositories`.
@category env
export def init [
  --search: directory
  # The directory to start scanning from when discovering repositories (implies `--discover`)
  --discovery (-d)
  # Enable repository search behavior (sets `discovery` to `true`)
  --return (-r)
  # Return the value after setting it
]: nothing -> oneof<nothing, record> {
  let current: record = repo-snapshot
  if $discovery or $search != null {
    set-repo discovery {enabled: true root: ($search | default $current.discovery.root)}
  }
  get-repo discovery
  | if $in.enabled {
    discover-git-repos $in.root
    | hydrate-git-context
    | prepend $current.path
    | uniq-by name
    | set-repo path
  }
  if $return { repo-snapshot }
}

# Add a project directory to the table of known repositories.
@category git
export def push [
  --search (-s): directory # Search for all git repositories within this directories
  --preview (-p) # Return the hydrated entry without altering enviornment variables
  --all (-a) # Search for all git repositories within three levels of the existing `discovery.root` directory
]: [
  nothing -> table<name: string, owner: string, path: directory>
  list<directory> -> table<name: string, owner: string, path: directory>
  table<name: path> -> table<name: string, owner: string, path: directory>
] {
  let input: oneof<nothing, list, table>;
  let current: record = repo-snapshot
  $input | match ($in | describe) {
    nothing => [
      ...($in | default [])
      ...(if $all { discover-git-repos $current.discovery.root } | default [])
      ...(if $search != null { discover-git-repos $search --depth=3 })
    ]
    list<string> | list<any> => { }
    _ => { get name }
  } | uniq
  | if ($in | is-empty) { error make --unspanned 'no repositories found' } else { }
  | difference $current.path.directory?
  | hydrate-git-context
  | if $preview { return $in } else if ($in | is-not-empty) { set-repo path }
  return (get-repo path)
}

# List the configured `git` repository names, their directories, and their owners.
@category git
export def list [
  regex?: string # Filter the included repositories using regex
]: nothing -> table {
  (repo-snapshot).path | match ($regex | describe) { nothing => { } string => { where name =~ $regex } }
}

# Aggregate a repository's issue and sub-issue hierarchy into a table.
@category git
export def tree [
  name: string@_repo-names # The name of the repository the issue belongs to
  --number (-n): int@_issue-numbers # The number of a parent issue to show the children nodes for
  --short (-s) # Only include sub-issue summary data, not the full sub-issue entries
]: nothing -> table<number: int, title: string, state: string, subissues: oneof<record, list>> {
  let view: bool = ($number | describe) == int
  let json: list = [number title state ...(if $short { [subIssuesSummary] } else { [parent subIssues] })]
  let repo: string = resolve-repo-name $name | format-repo-option
  ^gh issue --repo=($repo) ...(if $view { [view $number] } else { [list] }) --json=($json | str join ',')
  | ignore --stderr
  | from json
  | prune-tree-nodes
  | into int $.number!?
  | if $view { compact --empty } else { select ...$json }
  | if $short {
    rename --column={subIssuesSummary: summary}
  } else {
    upsert subIssues { default {nodes: []} | get nodes | reject $.url!? }
    | upsert parent { default {} | reject $.url!? }
  }
}

# List the `git` repositories in the configured projects directory.
@category git
export def show [
  regex: string = .+ # Regex pattern to match repository directory names
  --dirty (-d) # Only include repositories with non-clean states
  --gstat (-g) # Merge `gstat` informational columns instead of manual (only applies with `--status`)
  --fetch (-f) # Run `git fetch` before collecting information (forces `--no-cache`)
  --cache (-c) = true # Set false to force invalidation of any cached status values
]: nothing -> table {
  let current: record = repo-snapshot
  try {
    $current | validate-cache (if $cache { 4hr } else { 1hr })
  } catch {
    let data: table = $current.cache | if ($in | path exists) {
        open | collect {|x| rm --force $current.cache; $x }
      } else {
        mkdir ($in | path dirname); []
      }
    $current.path
    | where name =~ $regex
    | par-each {|row|
      alias wrapped = ^git -C $row.directory
      if $fetch { wrapped fetch --all | ignore --stdout --stderr }
      if $gstat {
        collect-gstat-data $row.directory | if not $dirty or $in.state != clean { }
      } else {
        wrapped status --short
        | ignore --stderr
        | parse-status-lines
        | if not $dirty and ($in | is-not-empty) {
          {name: $row.name branch: (wrapped branch --show-current | ignore --stderr) ...$in}
        }
      }
    } | compact
    | if ($in | is-not-empty) {
      let merged: table = prepend $data | uniq-by name --keep-last
      $merged | save --force $current.cache
      return $merged
    } else {
      return []
    }
  }
}

# Execute a closure from the root directory of a configured repository.
#
# The repository information record will be passed to the closure as a positional.
# Any pipeline input this function receives will be piped into the closure.
@category git
export def x [
  name: string@_repo-names # The name of the repository to execute the closure in
  closure: closure # The closure to run from the repository root
  --suppress (-s) # Run the closure with `do --ignore-errors` to suppress errors
]: oneof<any, nothing> -> oneof<any, nothing> {
  let repo: record = resolve-repo-name $name
  cd $repo.directory
  $in | do --ignore-errors=$suppress $closure $repo
}

# ——— utilities ———————————————————————————————————————————————————————————————

def validate-cache [ttl: duration = 4hr]: oneof<nothing, record> -> oneof<table, error> {
  let current: record = default (repo-snapshot)
  $current.cache | if $in == null or not ($in | path exists) {
    error make --unspanned 'repository cache file does not exist'
  } else if (ls $in | where modified > ((date now) - $ttl) | is-empty) {
    error make --unspanned $"repository cache file is stale \(TTL: ($ttl))"
  } else {
    let data: table = open $in
    if ($current.path | length) == ($data | length) { return $data }
    error make --unspanned 'repository inventory has been modified since last cache write'
  }
}

def prune-tree-nodes []: [table -> table record -> record] {
  match ($in | describe | str replace --regex '<.+$' '') {
    record => { }
    table => { where { get --optional parent subIssues subIssuesSummary | compact | any { is-not-empty } } }
  }
}

def hydrate-git-context []: oneof<directory, list<directory>> -> table<name: string, owner: string, directory: directory> {
  append []
  | where ($it | path type) == dir
  | uniq
  | par-each {|dir|
    ^git -C $dir config --get remote.origin.url out+err>|
    | complete
    | match $in.exit_code { 0 => { get stdout | str trim } _ => { return } }
    | parse --regex '(?<prefix>git@|https://)github.com[/\:](?<owner>\w+)/(?<name>[\w\-]+).git'
    | reject prefix
    | into record
    | default --empty ($dir | path dirname) name
    | default --empty (default-owner-name) owner
    | insert directory $dir
  } | collect
  | where $it has owner and $it has name
  | uniq-by --keep-last name
}

def default-owner-name []: nothing -> string {
  git config --global --get user.name out+err>|
  | complete
  | match $in.exit_code { 0 => { get stdout | str trim } _ => { whoami } }
}

def discover-git-repos [
  root: directory
  --depth: int = 3
]: nothing -> list<directory> {
  let exclude: list<string> = get-repo hidden | default ['**/.*/**']
  let include: glob = $root | path rejoin ** | into glob
  glob --depth=$depth --no-file --no-symlink --exclude=$exclude $include
  | where ($it | path join .git | path type) == dir
  | uniq
}

def collect-gstat-data [root: path]: nothing -> record {
  cd $root; gstat
  | transpose key value
  | where key !~ '^(idx|wt)_'
  | transpose --header-row
  | into record
  | rename --column={repo_name: name}
  | insert path $root
  # Reorders columns for neater rendering
  | select ...$COLS
}

def parse-status-lines []: string -> record {
  lines | str trim | compact --empty | if ($in | is-empty) {
    return {}
  } else {
    parse '{marker} {path}'
    | par-each --keep-order {|ln|
      match $ln.marker {
        ?? => {untracked: $ln.path}
        M | m => {modified: $ln.path}
        T | t => {file-type-change: $ln.path}
        A | a => {added: $ln.path}
        R | r => {renamed: $ln.path}
        C | c => {copied: $ln.path}
        U | u => {updated-unmerged: $ln.path}
      }
    } | into record
  }
}

def resolve-repo-name [
  name: string
]: nothing -> record<name: string, owner: string, directory: path> {
  get-repo path | default [] | where name == $name | first | default {
    error make --unspanned $"unable to resolve repository '($name)'"
  }
}

def format-repo-option []: record<owner: string, name: string> -> string { get owner name | path join }

# ——— completions ——————————————————————————————————————————————————————————————

def _repo-names []: nothing -> record {
  {
    options: {
      sort: true
      match_description: true
      completion_algorithm: fuzzy
    }
    completions: (
      get-repo path
      | default []
      | insert description {|row| $"[($row.owner)] ($row.directory)" }
      | rename --column={name: value}
      | select value description
    )
  }
}
def _issue-numbers [buffer: string]: nothing -> oneof<list, record> {
  {
    options: {
      sort: true
      match_description: true
      completion_algorithm: substring
    }
    completions: (
      match ($buffer | split words | last) {
        null => []
        $arg => {
          $"gh issue --repo=(resolve-repo-name $arg | format-repo-option) view "
          | commandline complete --detailed
        }
      }
    )
  }
}
