# The `local …`-prefixed forms of every `<module>/local` variant: `use <library root>/local.nu` gives
# `local alarm …`, `local completion …`, `local mods …`, for sessions that import a module's abstract form and want
# its full variant under a distinct name. The root barrel exposes the same variants as bare names and does not
# include this file, so `use <library root> *` adds no `local …` names to completions.
#
# Each variant is re-exported with `export use`, which makes its commands this module's own (`alarm set`), since a
# `use` reaches one level of commands only (an `export module` would be two). `alarm` and `mods` are the root
# barrel's wrappers, which declare their `main`.

export use mod.nu [ alarm mods ]

module completion {
  export use completion/local *
}
export use completion
