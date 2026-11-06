# Path helpers extending the builtin `path` commands, with the std and std-rfc path extras.

use std/util "path add"
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
    nothing if ($segments | is-empty) => { error make --unspanned 'path rejoin: nothing to join' }
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
  if $n == 0 { error make --unspanned 'path truncate: cannot keep zero segments' }
  let trim: closure = if $from =~ ^e {
    {|n: int| last $n }
  } else if $from =~ ^s {
    {|n: int| first $n }
  } else { error make --unspanned $'unknown value for `--from`: ($from)' }
  let glob: bool = $queue | any { describe | $in == string }
  $queue | par-each --keep-order {|item|
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
  if ($in | is-not-empty) {
    let prompt: string = $"open file with ($env.EDITOR? | default editor)"
    let choice: any = $in | input list --fuzzy $"(ansi dark_gray)($prompt)(ansi rst)"
    match ($choice | describe) { string => $choice _ => { $choice | get --optional $column } }
  } else if not $optional {
    error make $message
  }
}
