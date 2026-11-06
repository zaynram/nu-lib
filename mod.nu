# Root barrel of the module library: `use <library root> *` loads the commonly used modules.
#
# Modules are exposed under their own names (`pman upgrade`, `conf vars`, `mods edit`, ...); `windows` and
# `completion` are flattened (`win env`, `into completions`, ...). Modules that mix abstract and
# configuration-dependent commands are exposed through their full `<module>/local` variant. The `local` barrel
# gathers every `<module>/local` variant under its module's name (`local alarm set`, `local completion
# set-completer`, `local mods edit`): `use <library root> local`, or `local …` after `use <library root> *`.
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

export module local {
  # Every `<module>/local` variant, under its module's name: `local alarm …`, `local completion …`, `local mods …`.
  #
  # Each is re-exported with `export use`, which makes its commands this module's own (`alarm set`), since
  # `use <root> local` reaches one level of commands only (an `export module` would be two). `alarm` and `mods`
  # are the prelude's wrappers, which declare their `main`.

  export use prelude [ alarm mods ]

  module completion {
    export use completion/local *
  }
  export use completion
}

# ——— bootstrap ————————————————————————————————————————————————————————————————

const ROOT: path = path self .
const AUTOLOAD_FILE: string = 'local.nu'

# Write the autoload file that exposes every `<module>/local` variant unprefixed in interactive shells.
#
# The file loads the barrel as the overlay `__lib__`, activates the `local` barrel on top of it and hides `__lib__`
# again, which leaves the full variants as bare names (`alarm set`, `completion set-completer`, `mods edit`, …).
# Hiding an overlay reverts the environment it set up, so the file must run after the barrel is already loaded
# (autoload files run in name order: `local.nu` sorts after a file such as `abc.nu` that does `use <root> *`).
# With `--barrel` the file loads the barrel itself first and stands alone. Writing is idempotent: an existing file
# with the same content is left alone, and one with different content is kept unless `--force` is given.
@category env
export def init-local [
  --barrel (-b) # Load the whole barrel (`use <root> *`) in the file first, so it needs no other configuration
  --path (-p): path # The file to write (default: `local.nu` in the first user autoload directory)
  --force (-f) # Overwrite the file when its content differs
]: nothing -> record<path: path, action: string> {
  let file: path = $path | default { $nu.user-autoload-dirs | first | path join $AUTOLOAD_FILE } | path expand
  let text: string = [
    '# Written by `init-local` (nu-lib): the `<module>/local` variants as bare commands, via overlays.'
    (if $barrel {
      '# Loads the barrel itself; regenerate without --barrel if another autoload file already loads it.'
    } else {
      '# Needs the barrel loaded by an earlier autoload file (`use <root> *`); regenerate with --barrel otherwise.'
    })
    (if $barrel { $"use ($ROOT | to nuon) *" })
    $"overlay use ($ROOT | to nuon) as __lib__"
    'overlay use local'
    'overlay hide __lib__'
  ] | compact | str join (char newline) | $in + (char newline)
  let current: oneof<nothing, string> = if ($file | path type) == file { open --raw $file }
  let action: string = match $current {
    null => 'written'
    $same if $same == $text => 'unchanged'
    _ if $force => 'overwritten'
    _ => 'kept'
  }
  if $action in [written overwritten] {
    mkdir ($file | path dirname)
    $text | save --force $file
  }
  {path: $file action: $action}
}

# ——— activation ———————————————————————————————————————————————————————————————

export use prelude *

# ——— environment ——————————————————————————————————————————————————————————————

# Appends the library's directories missing from NU_LIB_DIRS, then runs only the `export-env` blocks of the modules
# whose set-up the barrel needs (`source-env` evaluates a module's environment block without importing it):
# - `conf` (login shells): the vendor scope's NU_LIB_DIRS, NU_PLUGIN_DIRS and PATH;
# - `mods` (interactive login shells): `mods_home`/`mods_refs` and the `use`/`hide` tracking hook;
# - `completion/local` (interactive login shells): the external completers' variables and PATH entry;
# - `proj` (interactive login shells): the registry scan of `$env.WORK` (skipped when WORK is unset; a scan within
#   the last day is reused) and the `std/dirs` ring;
# - `track` (interactive login shells): the `track::sync` and `track::focus` hooks (added once);
# - `windows` (WSL: `WSL_DISTRO_NAME` is set or the kernel release names Microsoft): splits the Windows entries of
#   PATH into WINPATH.
# Every block is idempotent, so loading the barrel again changes nothing.
export-env {
  const root: path = $ROOT
  let missing: list<path> = $NU_LIB_DIRS | where $it not-in ($env.NU_LIB_DIRS? | default [])
  if $missing != [] { $env.NU_LIB_DIRS = ($env.NU_LIB_DIRS? | default []) ++ $missing }
  if $nu.is-login { source-env ($root | path join conf mod.nu) }
  if $nu.is-interactive and $nu.is-login {
    source-env ($root | path join mods mod.nu)
    source-env ($root | path join completion local mod.nu)
    source-env ($root | path join proj mod.nu)
    source-env ($root | path join track mod.nu)
  }
  if $env.WSL_DISTRO_NAME? != null or $nu.os-info.kernel_version =~ '(?i)microsoft' {
    source-env ($root | path join windows mod.nu)
  }
}
