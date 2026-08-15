# ——— constants ———————————————————————————————————————————————————————————————

export const opt: record = {
  dc-glob: true
  reorder-cell-paths: true
  pipefail: true
  enforce-runtime-annotations: true
  native-clip: false
  cell-path-types: false
}

# ——— definitions —————————————————————————————————————————————————————————————

# Return the current experimental options as a record.
@category core
export def get-options []: nothing -> record {
  version
  | get experimental_options
  | split row ', '
  | parse '{k}={v}'
  | update v { into bool }
  | transpose --header-row
  | into record
}

# Execute the login shell process with experimental options set (idempotent).
@category core
export def set-options []: nothing -> nothing {
  if (get-options | select ...(cols)) == $opt { return }
  let neo: string = $opt | items {|k v| [$k $v] | str join '=' } | str join ', '
  exec $nu.current-exe --login --experimental-options=[($neo)]
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def cols []: nothing -> list { $opt | columns }
