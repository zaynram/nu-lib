# Environment utility module for script-friendly environment commands.
#
# `env from-bash` (in `from-bash.nu`) runs `bash` to read the variables a bash script sets; it is the owner's
# reimplementation of a fork of tesujimath/bash-env-nushell (MIT).

use error
use completion "into completions"

# `env from-bash` and `env parse`.
export use from-bash.nu
export use parse.nu

# Parse variables from a `.env` file (deprecated: `env parse` reads it, and more).
export alias dotenv = parse

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
#
# One name returns its value, several return a list of values, none returns `$env` without the prompt and
# config variables. The boolean flags take a value (`--optional=false`), since they default to true.
export def main [
  ...names: cell-path@_keys
  # Variable names to retrieve value(s) for
  --optional (-o) = true
  # Return null instead of raising an error when a variable is not found
  --ignore-case (-i) = true
  # Match variable names case-insensitively
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
  if $names == [] { return ($env | reject --optional ...$exclude) }
  let name: cell-path = $names | first
  let rest: list = $names | skip
  # `get a ...[]` returns a one-element list, so a single name is looked up on its own.
  if $rest == [] { return ($env | get --optional=($optional) --ignore-case=($ignore_case) $name) }
  $env | get --optional=($optional) --ignore-case=($ignore_case) $name ...$rest
}

# Set environment variables from the piped record, then `--merge`, then `name`/`value` (later ones win).
#
# Returns the record that was loaded, or prints `(no changes)` and returns nothing when there was nothing to set.
export def --env add [
  name?: string@_keys
  # Name of the variable to set the value of
  value: oneof<nothing, any> = null
  # Value to set under the `name` environment variable
  --merge: record = {}
  # Mapping of variables to load in the process environment
  --conversions (-c): table<name: string, to_string: closure, from_string: closure>
  # Conversions to add to `$env.ENV_CONVERSIONS` (they replace existing ones of the same name)
  --default (-d)
  # Only set variables that are missing from the process env or set to `null` there
]: oneof<nothing, record> -> oneof<record, nothing> {
  let vars: record = default {}
    | merge $merge
    | if $name != null { upsert $name $value } else { }
  let added: record = $conversions | default [] | each {|c| {$c.name: ($c | select to_string from_string)} } | into record
  let e: record = if $default {
      $vars | reject ...($vars | columns | where (null | has --nullable=false $it))
    } else { $vars }
    | if $added == {} { } else {
      upsert $.ENV_CONVERSIONS {|| $env.ENV_CONVERSIONS? | default {} | merge ($in | default {}) | merge $added }
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

# Test for the existence of variables: one name returns a bool, several (or a piped list) a list of bools.
export def has [
  ...names: string@_keys
  --nullable (-n) = true
  # Count variables set to `null` as existing (`--nullable=false` treats them as missing)
  --ignore-case (-i) = true
  # Match variable names case-insensitively
]: [
  nothing -> oneof<nothing, bool, list<string>>
  list<string> -> list<bool>
] {
  let keys: list<string> = $in | append $names
  if $keys == [] { error raise 'no variable names were provided' --kind invalid_argument }
  let found: list<bool> = $keys | each {|k|
    let wanted: string = if $ignore_case { $k | str lowercase } else { $k }
    let key: oneof<nothing, string> = $env
      | columns
      | where (if $ignore_case { $it | str lowercase } else { $it }) == $wanted
      | get 0?
    $key != null and ($nullable or ($env | get $key) != null)
  }
  # a single positional name returns its bool alone; a piped list always returns a list
  if $names != [] and ($keys | length) == 1 { $found | first } else { $found }
}

# Remove variables from the current scope.
export alias rm = hide-env

# ——— completions ——————————————————————————————————————————————————————————————

