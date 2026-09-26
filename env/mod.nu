# Environment utility module for script-friendly environment commands.

use ../completion "into completions"

def _keys []: nothing -> oneof<list, record> {
  $env | transpose value description
  # Filter out underscore-prefixed keys since they are often used only internally
  | where value !~ '^_+[_a-z\-]+$'
  # Show the native type of complex values instead of a huge serialization.
  | update description {||
    describe | if $in ends-with > { return $in }
    $in | to text | str trim
  } | into completions
}

# Get one or more environment variable values.
export def main [
  ...names: cell-path@_keys
  # Variable names to retrieve value(s) for
  --optional (-o) = true
  # Don't throw an error if the variable is not found
  --ignore-case (-i) = true
  # Retrieve the value with case-insensitive name matching
  --exclude (-e): list<cell-path> = [
    $.config!
    $.env_conversions!
    $.prompt_command!
    $.prompt_command_right!
    $.prompt_indicator!
    $.prompt_indicator_vi_insert!
    $.prompt_indicator_vi_normal!
    $.prompt_multiline_indicator!
    $.transient_prompt_command!
    $.transient_prompt_command_right!
    $.transient_prompt_multiline_indicator!
    $.reedline_lsp_servers!?
    $.pyenv_virtualenv_disable_prompt!?
    $.virtual_env_disable_prompt!?
  ]
  # Variables to exclude when no `names` are given
]: nothing -> oneof<nothing, string, record, any> {
  if $names == [] { return ($env | reject ...$exclude) }
  let name: cell-path = $names | first
  let rest: list = $names | skip
  $env | get --optional=($optional) --ignore-case=($ignore_case) $name ...$rest
}

# Set an environment variable.
export def --env add [
  name?: string@_keys
  # Name of the variable to set the value of
  value: oneof<nothing, any> = null
  # Value to set under the `name` environment variable
  --merge: record = {}
  # Mapping of variables to load in the process environment
  --conversions (-c): table<name: string, to_string: closure, from_string: closure>
  # Conversions to add to the `$env.ENV_CONVERSIONS` record
  --default (-d)
  # Only set values for variables missing or `null` from the process env
]: oneof<nothing, record> -> oneof<record, nothing> {
  let e: record = default {}
    | merge $merge
    | if $name != null { upsert $name $value } else { }
    | if $default {
      transpose name value
      | where not (has $it.name) or value == null
      | transpose --ignore-titles --as-record --header-row
    } else { }
    | if ($conversions | is-empty) { } else {
      upsert $.ENV_CONVERSIONS {
        ...($in | default {} | reject --optional $conversions.name)
        ...($conversions | each { [$in.name $in] } | into record)
        ...($env.ENV_CONVERSIONS | reject --optional ...$conversions.name)
      }
    }
  if ($e | is-not-empty) { load-env $e }
  return ($e | default --empty { print '(no changes)' })
}

# Select environment variables.
export def sel [
  ...names: cell-path@_keys
  # The variable name(s) to retrieve the value(s) for
  --optional (-o) = true
  # Don't throw an error if the variable is not found
  --ignore-case (-i) = true
  # Retrieve the value with case-insensitive name matching
]: nothing -> record {
  $env | select --optional=($optional) --ignore-case=($ignore_case) ...$names
}

# Test for the existence of variables
export def has [
  ...names: string@_keys
  --nullable (-n) = true
  # If `False`, treat existing variables set to `null` as missing
  --ignore-case (-i) = true
  # Check for variable existence without case sensitivity
]: [
  nothing -> oneof<nothing, bool, list<string>>
  list<string> -> list<bool>
] {
  append $names | match ($in | length) {
    0 => { error make --unspanned 'no variable names were provided' }
    1 if ($names | is-not-empty) => { first }
    _ => { }
  } | each {|k|
    ($env has $k) and $nullable or (
      $env | get --optional --ignore-case=($ignore_case) $k
    ) != null
  }
}

# Remove variables from the current scope.
export alias rm = hide-env

# Run a closure with a temporary environment and capture changes.
export def cap [
  closure: closure
  # Closure to run in the environment.
  --with (-e): record = {}
  # Environment variables to start with; merged with input records if both given
  --bail (-b)
  # Mapped to `--capture-errors` on the `do` invocation
]: oneof<nothing, record> -> oneof<record, table> {
  let e: record = match ($in | describe) {
    record if ($with | is-empty) => { }
    nothing => $with
    _ => { merge $with }
  }
  let c = $env | merge $e
  with-env $e {||
    do --env --capture-errors=$bail $closure
    | {output: $in}
    | insert $.changes {
      $env
      | transpose name after
      | insert before {|var|
        try { $c | get $var.name } catch { get $.code? }
      } | where before != $it.after
    }
  }
}
