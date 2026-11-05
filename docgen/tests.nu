#!/usr/bin/env -S nu --stdin

const NU_LIB_DIRS = [
  ($nu.data-dir | path basename --replace nupm | path join modules)
]
const SUITES: path = path self ./tests/suites

# Run the docgen test suites: `nu tests.nu`, or `use tests.nu` and call `tests`.
export def main [
  --test (-t): string@_test-names = '' # Only run tests whose command name matches
  --verbose (-v) # Print captured errors under failing tests
  --strict (-s) # Raise an error when any test fails, for CI and hooks
]: nothing -> table {
  use test
  test $SUITES --test=($test) --verbose=($verbose) --strict=($strict)
}

def _test-names []: nothing -> list<string> {
  glob ($SUITES | path join *.nu)
  | each { open $in | parse --regex 'def "(?<name>test [^"]+)"' | get name }
  | flatten
  | sort
}
