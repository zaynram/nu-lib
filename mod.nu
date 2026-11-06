# Root barrel of the module library: `use <library root> *` loads the commonly used modules.
#
# Modules are exposed under their own names (`pman upgrade`, `conf vars`, `mods edit`, ...); `windows` and
# `completion` are flattened (`win env`, `into completions`, ...). Modules that mix abstract and
# configuration-dependent commands are exposed through their full `<module>/local` variant.
#
# `export use` does not run a module's `export-env`, so the environment set-up the barrel needs is triggered by
# the `export-env` at the end, which loads only those blocks (see there).

# ——— constants ————————————————————————————————————————————————————————————————

export use conf/machine.nu [ NU_LIB_DIRS NU_PLUGIN_DIRS ]

# ——— barrels ——————————————————————————————————————————————————————————————————

module prelude {
  # Common-use barrel loader for the module library.

  # ——— commands ———————————————————————————————————————————————————————————————

  export module pman
  export module link
  export module reload
  export module edit
  export module path

  # ——— interfaces —————————————————————————————————————————————————————————————

  export use proj
  export use track
  export use time
  export use todo
  export use hook
  export use conf
  export use env
  export use error
  export use elevate

  # A `<module>/local` variant is re-exported inside a module of the original name. Its `main` is declared here,
  # delegating, because a re-exported `main` takes its module's name (`alarm local`); for the same reason the
  # subcommands of `alarm/local`, which has a `main`, are listed by name.

  export module alarm {
    export use alarm/local [ set unset list show ]

    # Show the alarms, or one alarm by name (delegates to `alarm/local`).
    @category productivity
    export def main [
      name?: string # Name of the alarm to check
    ]: nothing -> oneof<nothing, record, table> {
      use alarm/local
      local $name
    }
  }

  export module mods {
    export use mods/local *
    use mods

    # Show the modules loaded in the current session, or define new ones (delegates to `mods` in mods/mod.nu).
    @category core
    export def --env main [
      name?: string # Name of a module to define or show information about
      --all (-a) # Include overlays in the entries returned or searched
    ]: [
      nothing -> oneof<table<name: string, module_id: int>, list<string>, string>
      record -> oneof<path, list<path>>
      closure -> path
    ] {
      mods $name --all=$all
    }
  }

  # ——— bundles ————————————————————————————————————————————————————————————————

  export use windows *
  export use completion/local *
}

# ——— activation ———————————————————————————————————————————————————————————————

export use prelude *

# ——— environment ——————————————————————————————————————————————————————————————

# Appends the library's directories missing from NU_LIB_DIRS, then runs only the `export-env` blocks of the modules
# whose set-up the barrel needs (`source-env` evaluates a module's environment block without importing it):
# - `conf` (login shells): the vendor scope's NU_LIB_DIRS, NU_PLUGIN_DIRS and PATH;
# - `mods` (interactive login shells): `mods_home`/`mods_refs` and the `use`/`hide` tracking hook;
# - `completion/local` (interactive login shells): the external completers' variables and PATH entry;
# - `windows` (Linux, i.e. WSL): splits the Windows entries of PATH into WINPATH.
# Every block is idempotent, so loading the barrel again changes nothing.
export-env {
  const root: path = path self .
  let missing: list<path> = $NU_LIB_DIRS | where $it not-in ($env.NU_LIB_DIRS? | default [])
  if $missing != [] { $env.NU_LIB_DIRS = ($env.NU_LIB_DIRS? | default []) ++ $missing }
  if $nu.is-login { source-env ($root | path join conf mod.nu) }
  if $nu.is-interactive and $nu.is-login {
    source-env ($root | path join mods mod.nu)
    source-env ($root | path join completion local mod.nu)
  }
  if $nu.os-info.name == linux { source-env ($root | path join windows mod.nu) }
}
