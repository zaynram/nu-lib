# Path helpers extending the builtin `path` commands, with the std and std-rfc path extras.

use error
use std/util "path add"
use style
export use std-rfc/path [ with-extension with-parent with-stem ]

# Prepend (or append) directories to `$env.PATH`.
export alias add = path add

def join-with [sep: string]: list<string> -> path {
  path join | str replace --all --regex '[\\/]+' $sep
}

# Re-join a path with a uniform separator, appending any extra segments.
#
# Every run of `/` or `\` in the input and the segments collapses to `--sep`, so a
# Windows path seen from WSL comes out forward-slashed by default. As with `path join`,
# an absolute segment replaces everything before it. A list input re-joins each item.
@category path
export def rejoin [
  ...segments: string # Additional segments to append
  --sep (-s): string = '/' # Separator to join with
]: [
  nothing -> path
  string -> path
  list<string> -> list<path>
] {
  let input: oneof<nothing, string, list<string>> = $in
  match ($input | describe | str replace --regex '<.*' '') {
    nothing if ($segments | is-empty) => {
      error raise 'nothing to join' ...{
        kind: invalid_argument
        advice: 'pipe a path (or a list of paths), or give segments'
      }
    }
    list => { $input | each {|p| [$p] | append $segments | join-with $sep } }
    _ => { [$input] | append $segments | compact | join-with $sep }
  }
}

# Truncate paths to a number of segments, optionally relative to a base path.
#
# `--from end` (the default) keeps the last `n` segments, `--from start` the first `n`; only the first character
# of `--from` is checked, so `s`/`start` and `e`/`end` are equivalent. A negative `n` keeps every segment. Table
# input has its `name` column truncated.
@category path
export def truncate [
  n: int = -1 # The number of segments to keep (negative keeps all; zero is an error)
  --root (-r): path # Make the paths relative to this base path first
  --from (-f): string = end # Which segments to keep: those at the start or at the end
]: [
  table<name: string> -> table<name: string>
  list<oneof<path, string>> -> list<oneof<path, string>>
] {
  let queue: any = $in
  if $n == 0 {
    error raise 'cannot keep zero segments' ...{
      kind: invalid_argument
      advice: 'a negative count keeps every segment'
    }
  }
  let trim: closure = if $from =~ ^e {
    {|n: int| last $n }
  } else if $from =~ ^s {
    {|n: int| first $n }
  } else {
    error raise $"unknown --from '($from)'" ...{
      kind: invalid_argument
      advice: 'use start or end'
    }
  }
  let glob: bool = $queue | any ($it | describe) == string
  $queue | each {|item|
    let base: path = if $glob { $item } else { $item.name }
      | if $root == null { $in } else { path relative-to ($root | path expand) }
    let list: list<string> = $base | path split
    let keep: int = $list | length
      | if $n < 0 { $in } else { append $n | math min }
    let path: path = $list | do $trim $keep | path join
    if $glob { return $path }
    $item | update name $path
  } | collect
}

# Select a path from the input interactively (needs a terminal); empty input is an error unless `--optional`.
@category path
export def select [
  column: string = name # Column name to extract the path value from
  --message (-m): string = `no files to select from` # Error message if the input is empty
  --optional (-o) # Return nothing on empty input instead of making an error
]: [
  oneof<list, table> -> oneof<nothing, path>
  nothing -> nothing
] {
  let items: any = $in
  if ($items | is-not-empty) {
    let prompt: string = $"open file with ($env.EDITOR? | default editor)"
    let choice: any = $items | input list --fuzzy ($prompt | style paint dark_gray)
    match ($choice | describe) { string => $choice _ => { $choice | get --optional $column } }
  } else if not $optional {
    # The message is the caller's `--message`, whose span lies at the call site, so the code cannot be derived here.
    error raise $message ...{
      kind: invalid_argument
      code: 'path::select::invalid_argument'
    }
  }
}
