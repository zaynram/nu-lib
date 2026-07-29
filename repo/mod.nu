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
      from_string: {|s|
        $s | parse --regex `(?<discovery>\d{1})@(?<path>.*)`
        | into record
        | update discovery { into bool }
        | update path { split row (char esep) | hydrate-git-context }
      }
      to_string: {|v|
        if ($v | describe) == string { return $v }
        let n: int = $v.repo?.discovery | default false | into int
        let p: string = $v.repo?.path.directory | default [] | str join (char esep)
        return $"($n)@($p)"
      }
    }
  }
  # Always reassign the `$env.repo` value to pick up environment changes and
  # gracefully handle [de-]serialization issues on load.
  $env.repo = if $env not-has repo or $env.repo == null {
    # Sensible defaults for missing or null values.
    {path: [] discovery: false}
  } else if ($env.repo | describe) == string {
    # Process termination can cause converter to unload while retaining the variable value,
    # which can block reinitialization and throw errors on every command.
    # To avoid this case, we convert strings manually if detected when this module loads.
    do $env.ENV_CONVERSIONS.repo.from_string $env.repo
  } else if ($env.repo | describe) =~ ^record {
    $env.repo | upsert discovery { default false }
  } else { error make --unspanned $'received unknown type for `$env.repo`: ($env.repo | describe)' }
    # Upsert here the branches to ensure `$env.repo.discovery` is evaluated.
    | upsert path {|row| if $row.discovery { append (discover-git-repos | hydrate-git-context) } else { append [] } }
}

# Add a project directory to the `$env.PROJECTPATH`.
export def --env push [
  --preview (-p) # Return the hydrated entry without altering enviornment variables
  --all (-a) # Search for all git repositories within three levels of the user's home directory
]: [
  nothing -> table<name: string, owner: string, path: directory>
  list<directory> -> table<name: string, owner: string, path: directory>
  table<name: path> -> table<name: string, owner: string, path: directory>
] {
  let out: table = match ($in | describe | split words | first) {
    nothing if not $all => { error make --unspanned 'directories must be provided without `--all`' }
    nothing | list => { }
    table if $in has name => { get name }
  } | if $all { append (discover-git-repos) } else { }
    | where $env.repo?.path?.directory == null or $it not-in $env.repo.path.directory
    | hydrate-git-context
  if $preview { return $out } else { $env.repo.path ++= $out }
  return $env.repo.path
}

# List the `git` repositories in the configured projects directory.
export def --env list [
  regex: string = .+ # Regex pattern to match repository directory names
  --dirty (-d) # Only include directories that do not have a 'clean' state
  --gstat (-g) # Merge `gstat` informational columns instead of manual
  --fetch (-f) # Run `git fetch` before collecting information (forces `--no-cache`)
  --status (-s) # Return the status for each row in `$env.repo.path`
  --no-cache (-n) # Force invalidation of any cached status values
]: nothing -> table {
  if not $status { return $env.repo.path }
  let cached: oneof<table, nothing> = try { open $env.repo.cache } catch { ignore }
  if $fetch or $no_cache or ($cached | is-empty) or (
    (ls $env.repo.cache).0.modified < ('4 hours ago' | date from-human)
    or ($env.repo.path | length) != ($cached | length)
  ) {
    let dst: path = $env.repo.cache? | default { $nu.home-dir | path join .cache nu repo def.list.nuon }
    if not ($dst | path exists) {
      $dst | path dirname | mkdir $in
    } else {
      $dst | path basename --replace *.nuon | glob $in --exclude=[$dst] | if ($in | is-not-empty) { rm ...$in }
    }
    let out: table = $env.repo?.path
      | if ($in | is-empty) { return [] } else { where directory =~ $regex }
      | par-each {|row|
        let root: path = $row.directory
        if $fetch { git -C $root fetch --all | complete | ignore }
        if $gstat {
          let data: record = collect-gstat-data $root
          if $dirty and $data.state != clean { return $data }
        } else {
          let state: record = git -C $root status --short out+err>| to text | parse-status-lines
          if $dirty and ($state | is-empty) { return null }
          let branch: string = git -C $root branch --show-current out+err>| to text | str trim
          $row | select name | insert branch $branch | merge $state
        }
      } | compact | collect
    # Avoid caching empty data in case this runs prior to repo path population.
    if ($out | is-empty) { return [] }
    try {
      $env.repo.cache = $dst
      # Merge the new value into the old value so we don't invalidate excluded entries
      $cached | default []
      | where name not-in $out.name
      | append $out
      | save --progress --force $dst
      return $out
    } catch {|err|
      rm --force $dst
      $env.repo.cache = null
      error make --unspanned {msg: 'unable to cache repository info' inner: [$err]}
    }
  } else {
    return $cached
  }
}

# ——— utilities ———————————————————————————————————————————————————————————————

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

def discover-git-repos []: nothing -> list<directory> {
  glob $"($nu.home-dir)/**/.git" --depth=3 --no-file --no-symlink | path dirname
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
