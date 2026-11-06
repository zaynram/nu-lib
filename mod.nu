# Root barrel of the module library: `use <library root> *` loads the commonly used modules.
#
# The surface itself lives in `prelude.nu` (see there for what is exposed and how its environment set-up runs);
# this file re-exports it and adds the `local` barrel, which gathers every `<module>/local` variant under its
# module's name (`local alarm set`, `local completion set-completer`, `local mods edit`): `use <library root>
# local`, or `local …` after `use <library root> *`. Interactive shells that want the surface without the
# `local …` prefixes load `prelude.nu` instead (`init-local` writes that autoload file).

# ——— surface ——————————————————————————————————————————————————————————————————

export use prelude.nu *

# ——— local barrel —————————————————————————————————————————————————————————————

export module local {
  # Every `<module>/local` variant, under its module's name: `local alarm …`, `local completion …`, `local mods …`.
  #
  # Each is re-exported with `export use`, which makes its commands this module's own (`alarm set`), since
  # `use <root> local` reaches one level of commands only (an `export module` would be two). `alarm` and `mods`
  # are the prelude's wrappers, which declare their `main`.

  export use prelude.nu [ alarm mods ]

  module completion {
    export use completion/local *
  }
  export use completion
}

# ——— environment ——————————————————————————————————————————————————————————————

# `export use` does not run `prelude.nu`'s `export-env`; run the same loaders it runs (idempotent).
export-env {
  const root: path = path self .
  source-env ($root | path join loaders.nu)
}
