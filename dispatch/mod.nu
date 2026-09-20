# Extensions to the `match` built-in for common complex cases.

use ../validate

def return-or-exec [
  execute: bool = true
  --errors = true
  --input: any
  ...rest: any
]: oneof<nothing, any> -> oneof<nothing, any> {
  if not $execute or ($in | describe) != closure { } else {
    let c: closure;
    $input | do --capture-errors=$errors $c ...$rest
  }
}

# Dispatch based on dynamic predicate evaluation.
@category core
export def pred [
  arms: table<if: oneof<bool, closure>, then: any>
  # Cases in the form of records containing a condition and value to return or closure to run
  --args (-a): list<string> = []
  # Arguments to pass to any `$.condition` closures
  --exec (-x)
  # When the matched value is a closure, run it and return its result
  --pipe (-p)
  # Like `--exec`, but with the pipeline input piped into the matched closure
  --input (-i): any = null
  # Pipe this value to any matched closures (useful for closure input that differs from this function)
  --default: any = null
  # Fallback value (or closure) when no arm matches, `_` included
  --errors (-e)
  # Run `--exec`/`--pipe` closures with `--capture-errors`
  --mode (-m): string@[first last all] = first
  # Whether to return the first match (short-circuit), last match, or all matches.
  ...rest: any
  # Arguments to pass to any matched `$.exec` closure
]: oneof<nothing, any> -> oneof<nothing, error, any> {
  # Use pipeline input if `$pipe`, otherwise use the `$input` value
  let input: any = if $pipe { } else { $input }
  # Automatically enable execution for any flag that implies it
  let do: bool = $exec or $pipe or $input != null
  # Validate the `$mode` to avoid errors from `run-internal`
  let mode: string = $mode | validate string '^(all|first|last)$' | do $in
  # Filter the arms, evaluating closures as necessary and letting `where` handle non-booleans
  $arms | where {|| $in.if? | return-or-exec --errors=false ...$args }
  # Dynamic mode evaluation allows us to ignore list wrapping for the rest of the function
  | match $mode { all => { } $m => { run-internal $m } }
  # Use `each` to preserve list wrapping of the input (`par-each` errors on non-lists)
  | each {|| $in.then? | return-or-exec $do --errors=$errors --input=$input ...$rest }
}

# The value of the first arm naming `type`, else of the first naming `_`, wrapped in a list
# so that an arm holding `null` stays distinguishable from no arm at all.
def arm-for [arms: record type: string]: nothing -> list<any> {
  mut fallback: list<any> = []
  for arm in ($arms | transpose type value) {
    let names: list<string> = $arm.type | split row '|' | str trim
    if $type in $names { return [$arm.value] }
    if ($fallback | is-empty) and _ in $names { $fallback = [$arm.value] }
  }
  $fallback
}

# Dispatch based on the outermost type of an item.
#
# Precedence: an arm naming the type, then the `_` arm, then `--default`.
@category core
export def type [
  arms: record
  # Mapping of type names to values or closures; `|` (unions) and `_` (match-all) in keys are honored
  --exec (-x)
  # When the matched value is a closure, run it and return its result
  --pipe (-p)
  # Like `--exec`, but with the pipeline input piped into the matched closure
  --input (-i): any = null
  # Pipe this value to any matched closures (useful for closure input that differs from this function)
  --default: any = null
  # Fallback value (or closure) when no arm matches, `_` included
  --errors (-e)
  # Run `--exec`/`--pipe` closures with `--capture-errors`
  ...rest: any
  # Arguments to pass to a matched closure
]: oneof<nothing, any> -> oneof<nothing, any> {
  let value: any = $in
  # Automatically enable execution for any flag that implies it
  let do: bool = $exec or $pipe or $input != null
  # Not `split words`: hyphenated names such as `cell-path` must survive intact.
  let type: string = $in | describe | str replace --regex '<.*' ''
  # One walk with an early `return`: entering `update` and two `where` closures costs more
  # than scanning the handful of arms by hand.
  let matched: list<any> = arm-for $arms $type
  if ($matched | is-empty) { $default } else { $matched.0 }
  | return-or-exec $do --errors=$errors --input=(if $pipe { $value } else { $input }) ...$rest
}

# Run closures based on the current execution platform.
@category platform
export def os [
  arms: oneof<record, record<linux: any, macos: any, windows: any, bsd: any>> = {}
  # Mapping of OS names to values or closures
  --default (-d): any = null
  # Use this if no item was provided for the current platform
  --execute (-e) = true
  # If the resolved value is a closure, run it and return the result
  --capture (-c) = true
  # Capture any errors raised when executing a closure (only effective with `--execute`)
  ...args: any
  # Arguments to pass through to the closure
]: oneof<record, nothing> -> oneof<nothing, any> {
  default $arms
  | get --optional $nu.os-info.name
  | default $default
  | match ($in | describe) {
    closure if $execute => { do --ignore-errors=(not $capture) $in ...$args }
    _ => { return $in }
  }
}
