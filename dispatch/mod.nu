# Extensions to the `match` built-in for common complex cases.

# Dispatch based on the outermost type of an item.
@category core
export def type [
  arms: record
  # Mapping of type names to values or closures; `|` (unions) and `_` (match-all) in keys will be honored
  --exec (-x)
  # When the match value is a closure, execute it and return it's result
  --pipe (-p)
  # Similar to `--exec`  but with the pipeline input piped to any matched closures
  --default: any = null
  # Value to return if the matched value (or return value with `--exec`) is `null`
  --errors (-e)
  # Whether to run `--exec`/`--pipe` closures with `--capture-errors`
  ...rest: string
  # Arguments to pass to any matched closure if `--exec` is given
]: oneof<nothing, any> -> oneof<nothing, any> {
  let value: any = $in
  let type: string = $in | describe | split words | first
  $arms
  | if $default != null { default $default _ } else { }
  | transpose type value
  | update $.type { split row '|' | str trim | compact --empty }
  | where type has $type or type has _
  | sort-by type --reverse
  | get --optional $.0?.value
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
