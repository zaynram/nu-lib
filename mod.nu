# Root barrel of the module library: `use <library root> *` loads the commonly used modules.
#
# Modules are exposed under their own names (`pman upgrade`, `conf vars`, `mods edit`, ...); `windows` and
# `completion` are flattened (`win env`, `into completions`, ...). Modules that mix abstract and
# configuration-dependent commands are exposed through their full `<module>/local` variant, as bare names; nothing
# exposes `local …`-prefixed forms (a prefixed name and its bare twin would be one declaration, so they could not be
# hidden separately and would clutter completions).
#
# `export use` does not run a module's `export-env`, so the environment set-up the surface needs is triggered by
# the `export-env` at the end, which runs only the blocks the surface needs, under guards (see there).

# ——— constants ————————————————————————————————————————————————————————————————

export use conf/machine.nu [ NU_LIB_DIRS NU_PLUGIN_DIRS ]

const ROOT: path = path self .
const AUTOLOAD_FILE: string = 'nu-lib.nu'

# ——— commands ———————————————————————————————————————————————————————————————

export module pman
export module link
export module reload
export module edit
export module path
export module session

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

# ——— bootstrap ————————————————————————————————————————————————————————————————

# Write the autoload file that loads the library's interactive surface: a parse-time `const NU_LIB_DIRS` naming
# the library root, then `use <root> *`.
#
# The `use` loads the environment set-up and every command of this barrel, with the `<module>/local` variants as
# bare names (`alarm set`, `mods edit`, `set-completer`, …). The constant comes first because the barrel's modules
# import each other by bare name, so the root must be on the include path when the barrel parses: without it the
# file loads only in a shell whose configuration already lists the root. Note that the barrel exports its own
# `NU_LIB_DIRS` constant (the root and Nushell's module directories), which shadows a constant of the same name the
# configuration defines once the file has loaded: a module directory of your own must also be in
# `$env.NU_LIB_DIRS`, which the parser consults after the constant. Writing is idempotent: an existing file
# with the same content is left alone, and one with different content is kept unless `--force` is given.
@category env
export def init-local [
  --path (-p): path # The file to write (default: `nu-lib.nu` in the first user autoload directory)
  --force (-f) # Overwrite the file when its content differs
]: nothing -> record<path: path, action: string> {
  let file: path = $path | default { $nu.user-autoload-dirs | first | path join $AUTOLOAD_FILE } | path expand
  let text: string = [
    '# Written by `init-local` (nu-lib): the interactive command surface, local variants as bare names.'
    '# The constant puts the library root on the include path before the barrel parses (its modules import each other by name);'
    '# the barrel then exports its own NU_LIB_DIRS constant, so keep other module directories in $env.NU_LIB_DIRS too.'
    $"const NU_LIB_DIRS: list<path> = [($ROOT | to nuon)]"
    $"use ($ROOT | to nuon) *"
  ] | str join (char newline) | $in + (char newline)
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

# ——— environment ——————————————————————————————————————————————————————————————

# Runs the `export-env` blocks the surface needs, as guarded `use` statements: the barrel has already parsed these
# modules, so a `use` here re-parses nothing and only runs the module's environment block when its statement
# executes (`source-env <file>` would re-parse six module files as scripts on every load, guards or not: ~45 ms).
# First the library's directories missing from NU_LIB_DIRS are appended; then:
# - `conf` (login shells): the vendor scope's NU_LIB_DIRS, NU_PLUGIN_DIRS and PATH;
# - `mods` (interactive login shells): `mods_home`/`mods_refs` and the `use`/`hide` tracking hook;
# - `completion/local` (interactive login shells): the external completers' variables and PATH entry;
# - `proj` (interactive login shells): the `std/dirs` ring and, when WORK is set and the registry snapshot is
#   missing or stale (the kind directories changed, or it is older than a day), a background refresh of it; with a
#   fresh snapshot, or without WORK, import scans nothing;
# - `track` (interactive login shells): the `track::sync` and `track::focus` hooks (added once);
# - `windows` (WSL: `WSL_DISTRO_NAME` is set or the kernel release names Microsoft): splits the Windows entries of
#   PATH into WINPATH.
# Every block is idempotent, so loading the barrel again changes nothing.
export-env {
  let missing: list<path> = $NU_LIB_DIRS | where $it not-in ($env.NU_LIB_DIRS? | default [])
  if $missing != [] { $env.NU_LIB_DIRS = ($env.NU_LIB_DIRS? | default []) ++ $missing }
  # File paths, not bare names: inside this module a bare `mods` is the wrapper above, which has no env block.
  if $nu.is-login { use conf }
  if $nu.is-interactive and $nu.is-login {
    use mods
    use completion/local
    use proj
    use track
  }
  if $env.WSL_DISTRO_NAME? != null or $nu.os-info.kernel_version =~ '(?i)microsoft' { use windows }
}
