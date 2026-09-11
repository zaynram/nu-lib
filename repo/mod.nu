# Repository aggregation utilities and resolvers (GitHub-only for now).

# nu-lint-ignore-file: string_param_as_path

# ——— constants ———————————————————————————————————————————————————————————————

const gstat_cols: list<string> = [
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

# ——— definitions —————————————————————————————————————————————————————————————

export-env {
  # Only set the conversion if it is not already loaded (avoids serialization round-trip).
  if $env.ENV_CONVERSIONS not-has repo {
    $env.ENV_CONVERSIONS.repo = {
      from_string: {|s?|
        $s | default $env.repo? | try {
          parse --regex `(?<discovery>\d{1})@(?<path>.*)`
          | into record
          | update discovery { into bool }
          | update path { split row (char esep) | uniq | hydrate-git-context }
        } catch {
          return {discovery: false cache: null path: []}
        }
      }
      to_string: {|v?|
        if ($v | describe) !~ ^record { return ($v | default '') }
        let n: int = $v.repo?.discovery | default false | into int
        let p: string = $v.repo?.path.directory | default [] | uniq | str join (char esep)
        return $"($n)@($p)"
      }
    }
  }
  # Skip remaining initialization unless de-serializing or setting defaults.
  if $env not-has repo or ($env.repo | describe) == string { env --load }
}

export def --env env [
  --find (-f)
  # Enable repository search behavior (sets `$env.repo.discovery` to `true`)
  --load (-l)
  # Load the environment into the current process, if not done so already
  --show (-s)
  # Return the user environment, as a record
]: nothing -> oneof<nothing, record> {
  if $load {
    # Always reassign the `$env.repo` value to pick up environment changes and gracefully handle [de-]serialization issues on load.
    $env.repo = {discovery: ($env.repo?.discovery? | into bool --relaxed | $in or $find) cache: null path: []}
      | match ($env.repo? | describe | split words | first) {
        # Sensible defaults for missing or null values.
        nothing => { }
        # Process termination can cause converter to unload while retaining the variable value, which can block reinitialization and throw errors on every command.
        # To avoid this case, we convert strings manually if detected when this module loads.
        string => { do --capture-errors $env.ENV_CONVERSIONS.repo.from_string $env.repo }
        record => { merge deep --strategy=prepend $env.repo }
        $t => { error make --unspanned $'received unknown type for `$env.repo`: ($t)' }
        # Upsert here the branches to ensure `$env.repo.discovery` is evaluated.
      } | into record
      | if $find { upsert path { append (discover-git-repos | hydrate-git-context) | uniq-by name } } else { }
  }
  if $show or not $load { return $env.repo? }
}

# Add a project directory to the `$env.repo.path`.
export def --env push [
  --search (-s): list<directory> = [] # Search for all git repositories within these directories
  --preview (-p) # Return the hydrated entry without altering enviornment variables
  --all (-a) # Search for all git repositories within three levels of the user's home directory
]: [
  nothing -> table<name: string, owner: string, path: directory>
  list<directory> -> table<name: string, owner: string, path: directory>
  table<name: path> -> table<name: string, owner: string, path: directory>
] {
  match ($in | describe | split words | first) {
    table => { get name }
    nothing => [
      ...($in | default [])
      ...(if $all { discover-git-repos } | default [])
      ...($search | par-each { discover-git-repos $in --depth=2 } | flatten)
    ]
    list => { }
  } | uniq
  | if ($in | is-empty) { error make --unspanned 'no repositories found' } else { }
  | difference $env.repo.path.directory
  | hydrate-git-context
  | if $preview { return $in } else if ($in | is-not-empty) { $env.repo.path ++= $in }
  return $env.repo.path
}

# List the configured `git` repository names, their directories, and their owners.
export def list [
  regex?: string # Filter the included repositories using regex
]: nothing -> table {
  $env.repo.path | match $regex { null => { } $r => { where name =~ $r } }
}

# Aggregate a repository's issue and sub-issue hierarchy into a table.
export def tree [
  name?: string@_repo-names # The name of the repository the issue belongs to
  --number (-n): int@_issue-numbers # The number of a parent issue to show the children nodes for
  --short (-s) # Only include sub-issue summary data, not the full sub-issue entries
]: nothing -> table<number: int, title: string, state: string, subissues: oneof<record, list>> {
  if $name == null { error make --unspanned 'no repository was specified' }
  resolve-repo-name $name
  | wrap name
  | default [number title state] json
  | update json { if $short { append [subIssuesSummary] } else { append [parent subIssues] } | str join , }
  | insert args {|row| match $number { null => [list] $n => [view $n] } | append [--json=($row.json)] }
  | collect {|row|
    $row.name
    | run-gh-with-repo issue ...$row.args
    | from json
    | prune-tree-nodes
    | update number { into int }
    | match $number { null => { select ...$row.json } _ => { compact --empty } }
    | if $short {
      rename --column={subIssuesSummary: summary}
    } else {
      update subIssues { get nodes | reject url }
      | update parent { reject url }
    }
  }
}

# List the `git` repositories in the configured projects directory.
export def --env show [
  regex: string = .+ # Regex pattern to match repository directory names
  --dirty (-d) # Only include repositories with non-clean states
  --gstat (-g) # Merge `gstat` informational columns instead of manual (only applies with `--status`)
  --fetch (-f) # Run `git fetch` before collecting information (forces `--no-cache`)
  --cache (-c) = true # Set false to force invalidation of any cached status values
]: nothing -> table {
  try {
    validate-cache (if $cache { 4hr } else { 1hr })
  } catch {
    mkdir $nu.cache-dir
    let nuon: path = $env.repo.cache? | default { $nu.cache-dir | path join repositories.nuon }
    $env.repo.cache = $nuon
    let data: table = try { open $nuon } | default []
    rm --force $nuon
    $env.repo.path | where name =~ $regex | par-each {|row|
      alias _git = git -C $row.directory
      if $fetch { _git fetch --all | complete | ignore }
      if $gstat {
        collect-gstat-data $row.directory
        | if $dirty and $in.state == clean { ignore } else { }
      } else {
        _git status --short out+err>| to text
        | parse-status-lines
        | if $dirty and ($in | is-empty) { ignore } else {
          let state: record = $in
          _git branch --show-current out+err>| to text
          | str trim
          | wrap branch
          | insert name $row.name
          | merge $state
        }
      }
    } | compact
    | collect {|out|
      if ($out | is-empty) { return [] }
      $data
      | where name not-in $out.name
      | append $out
      | save --progress --force $nuon
      return $out
    }
  }
}

# Execute a closure from the root directory of a configured repository.
#
# The repository information record will be passed to the closure as a positional.
# Any pipeline input this function receives will be piped into the closure.
export def exec [
  name: string@_repo-names # The name of the repository to execute the closure in
  closure: closure # The closure to run from the repository root
  --suppress (-s) # Run the closure with `do --ignore-errors` to suppress errors
]: oneof<any, nothing> -> oneof<any, nothing> {
  let repo: record = resolve-repo-name $name
  cd $repo.directory
  $in | if $suppress {
    do --ignore-errors $closure $repo
  } else {
    do --capture-errors $closure $repo
  }
}

# ——— utilities ———————————————————————————————————————————————————————————————

def validate-cache [ttl: duration = 4hr]: nothing -> oneof<table, error> {
  if $env.repo?.cache? == null or not ($env.repo.cache | path exists) {
    error make --unspanned 'repository cache file does not exist'
  }
  if (ls $env.repo.cache | where modified > (date now | $in - $ttl) | is-empty) {
    error make --unspanned $"repository cache file is stale \(TTL: ($ttl))"
  }
  let data: table = open $env.repo.cache
  if ($env.repo.path | length) == ($data | length) { return $data }
  error make --unspanned 'repository inventory has been modified since last cache write'
}

def prune-tree-nodes []: [table -> table record -> record] {
  match ($in | describe | split words | first) {
    record => { }
    table => { where { get --optional parent subIssues subIssuesSummary | compact | any { is-not-empty } } }
  }
}

def hydrate-git-context []: oneof<directory, list<directory>> -> table<name: string, owner: string, directory: directory> {
  append []
  | where ($it | path type) == dir
  | uniq
  | par-each {|dir|
    git -C $dir config --get remote.origin.url out+err>|
    | complete
    | match $in.exit_code { 0 => { get stdout | str trim } _ => { return } }
    | parse --regex '(?<prefix>git@|https://)github.com[/\:](?<owner>\w+)/(?<name>[\w\-]+).git'
    | reject prefix
    | into record
    | upsert name { default { $dir | path dirname } }
    | upsert owner { default { default-owner-name } }
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
  root: directory = $nu.home-dir
  --depth: int = 3
]: nothing -> list<directory> {
  glob ($root | path join ** .git) --depth=$depth --no-file --no-symlink | path dirname | uniq
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
  | select ...$gstat_cols
}

def parse-status-lines []: string -> record {
  lines | str trim | compact --empty | if ($in | is-empty) {
    return {}
  } else {
    parse '{marker} {path}' | each {|ln|
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
  $env.repo?.path | where name == ($name | str trim) | if ($in | is-not-empty) {
    return $in.0
  } else {
    error make --unspanned $"unable to resolve repository '($name)'"
  }
}

def format-repo-option []: record<owner: string, name: string> -> string { get owner name | path join }

def --wrapped run-gh-with-repo [subcommand: string ...rest: string]: record<owner: string, name: string> -> string {
  gh $subcommand --repo=($in | format-repo-option) ...$rest
  | complete
  | match $in {
    {exit_code: 0 stdout: $s} => { return $s }
    {exit_code: $n stderr: $s} => {
      error make {
        msg: $'github CLI exited with code ($n)'
        code: `common::repo::gh::non_zero_exit_code`
        label: {text: arguments span: (metadata $rest).span}
        help: $"[stderr]\n($s)"
      }
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _repo-names []: nothing -> record {
  {
    options: {
      sort: true
      match_description: true
      completion_algorithm: fuzzy
    }
    completions: (
      $env.repo?.path
      | insert description {|row| $"[($row.owner)] ($row.directory)" }
      | rename --column={name: value}
      | select value description
    )
  }
}
def _issue-numbers [context: string]: nothing -> oneof<list, record> {
  {
    options: {
      sort: true
      match_description: true
      completion_algorithm: substring
    }
    completions: (
      match ($context | split words | last) {
        null => []
        $arg => {
          $"gh issue --repo=(resolve-repo-name $arg | format-repo-option) view "
          | commandline complete --detailed
        }
      }
    )
  }
}
