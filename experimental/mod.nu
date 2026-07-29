# ——— constants ———————————————————————————————————————————————————————————————

export const opt: record = {
  dc-glob: true
  reorder-cell-paths: true
  pipefail: true
  enforce-runtime-annotations: false
  native-clip: true
  cell-path-types: true
}

# ——— definitions —————————————————————————————————————————————————————————————

# Return a boolean indicating if the experimental options were set.
@category misc
export def has-options []: nothing -> bool {
  $env has NU_EXPERIMENTAL_OPTIONS and ($env.NU_EXPERIMENTAL_OPTIONS | is-not-empty)
}

# Execute the login shell process with experimental options set (idempotent).
@category core
export def set-options [
  --force (-f) # Force process replacement even if experimental options are set
]: nothing -> nothing {
  if not $force and (has-options) { return }
  let neo: string = $opt | items {|k v| [$k $v] | str join '=' } | str join ', '
  with-env {NU_EXPERIMENTAL_OPTIONS: $neo} { exec $nu.current-exe --login }
}
