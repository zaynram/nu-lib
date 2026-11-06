# The environment set-up of the library's surface, in a file with no module imports.
#
# `prelude.nu` and the root `mod.nu` run this file with `source-env` from their `export-env`. It must stay free of
# `use` statements for modules that have an `export-env`: `source-env` executes a file's top-level statements, and a
# `use` executed that way runs the imported module's environment block unguarded.

use conf/machine.nu [ NU_LIB_DIRS ]

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
  const root: path = path self .
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
