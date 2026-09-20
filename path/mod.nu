# Path helpers extending the builtin `path` commands, with the std and std-rfc path extras.

use std/util "path add"

# `with-extension`, `with-parent`, `with-stem`
export use std-rfc/path *

# Prepend (or append) directories to `$env.PATH`.
export alias add = path add

def join-with [sep: string]: list<string> -> path {
  path join | str replace --all --regex '[\\/]+' $sep
}

# Re-join a path with a uniform separator, appending any extra segments.
#
# Every run of `/` or `\` in the input and the segments collapses to `--sep`, so a
# Windows path seen from WSL comes out forward-slashed by default.
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

# Truncate a path by segment count or relativity to a base path.
#
# The `--from` argument uses regex matching on the first character
# so `--from s` and `--from start` are both valid and will result
# in the same behavior.
@category path
export def truncate [
  n: int = -1 # The number of segments to truncate to
  --root (-r): path # The base path to use as relative anchor
  --from (-f): string = end # Remove segments from start|end
]: [
  table<name: string> -> table<name: string>
  list<oneof<path, string>> -> list<oneof<path, string>>
] {
  let queue: any = $in
  let trim: closure = if $from =~ e {
    {|n: int| last $n }
  } else if $from =~ s {
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

# Select a path from the input interactively.
@category path
export def select [
  column: string = name # Column name to extract the path value from
  --message (-m): string = `no files to select from` # Error message if the input is empty
  --optional (-o) # No-op on empty input instead of making an error
]: [
  oneof<list, table> -> path
  nothing -> list
] {
  if ($in | is-not-empty) {
    let prompt: string = $"open file with ($env.EDITOR? | default editor)"
    let choice: any = $in | input list --fuzzy $"(ansi dark_gray)($prompt)(ansi rst)"
    match ($choice | describe) { string => $choice _ => { $choice | get --optional $column } }
  } else if not $optional {
    error make $message
  }
}
