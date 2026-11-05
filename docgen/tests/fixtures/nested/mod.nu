# nu-lint-ignore-file: some_file_rule
# A module whose surface lives in aliases, constants, and submodules.
# topiary: disable

# ——— definitions ———

export const LIMIT: int = 3

# nu-lint-ignore: some_rule
# Shorthand for a hidden listing.
export alias short = ls -a

# nu-lint-ignore: some_rule
# A top-level command.
export def top []: nothing -> int { $LIMIT }

# A re-exported file module: its commands surface on this module, not as a row.
export use ../single.nu

# A submodule, importable with `use nested sub`.
export module sub {
  # The submodule's own entry point.
  export def main []: nothing -> string { 'sub' }
  # A nested command.
  export def inner []: nothing -> int { 1 }
  export alias al = inner
  export const DEEP: string = 'd'
  export module leaf {
    export def tip []: nothing -> int { 2 }
  }
}
