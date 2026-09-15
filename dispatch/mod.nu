# Extensions to the `match` built-in for common complex cases.

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
  --default: any = null
  # Fallback value (or closure) when no arm matches, `_` included
  --errors (-e)
  # Run `--exec`/`--pipe` closures with `--capture-errors`
  ...rest: string
  # Arguments to pass to a matched closure
]: oneof<nothing, any> -> oneof<nothing, any> {
  let value: any = $in
  # Not `split words`: hyphenated names such as `cell-path` must survive intact.
  let type: string = $in | describe | str replace --regex '<.*' ''
  let table: table<type: list<string>, value: any> = $arms | transpose type value | update type { split row '|' | str trim }
  [
    ...($table | where type has $type)
    ...($table | where type has _)
    ...(if $default == null { [] } else { [{type: [_] value: $default}] })
  ] | get --optional 0.value
  | match ($in | describe) {
    closure if $exec => { do --capture-errors=$errors $in ...$rest }
    closure if $pipe => { let c: closure; $value | do --capture-errors=$errors $c ...$rest }
    _ => { }
  }
}

# Run closures based on the current execution platform.
@category platform
export def --wrapped os [
  arms: oneof<record, record<linux: any, macos: any, windows: any, bsd: any>> = {}
  # Mapping of OS names to values or closures
  --default (-d): any = null
  # Use this if no item was provided for the current platform
  --execute (-e) = true
  # If the resolved value is a closure, run it and return the result
  --capture (-c) = true
  # Capture any errors raised when executing a closure (only effective with `--execute`)
  ...args: string
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
