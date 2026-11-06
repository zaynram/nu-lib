# The library's common-use surface: `use <root>/prelude.nu *` loads it flat, with the `<module>/local` variants
# as bare names and no `local …` prefixes. The root barrel (`mod.nu`) re-exports this file and adds the `local`
# barrel; `init-local` writes the autoload file that loads this one.
#
# Modules are exposed under their own names (`pman upgrade`, `conf vars`, `mods edit`, ...); `windows` and
# `completion` are flattened (`win env`, `into completions`, ...). Modules that mix abstract and
# configuration-dependent commands are exposed through their full `<module>/local` variant.
#
# `export use` does not run a module's `export-env`, so the environment set-up the surface needs is triggered by
# the `export-env` at the end, which loads only those blocks (see there).

# ——— constants ————————————————————————————————————————————————————————————————

export use conf/machine.nu [ NU_LIB_DIRS NU_PLUGIN_DIRS ]

const ROOT: path = path self .
const AUTOLOAD_FILE: string = 'local.nu'

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

# ——— bootstrap ————————————————————————————————————————————————————————————————

# Write the autoload file that loads the library's interactive surface: `use <root>/prelude.nu *`.
#
# That one line loads the environment set-up and every command of the prelude, with the `<module>/local` variants
# as bare names (`alarm set`, `mods edit`, `set-completer`, …) and none of the `local …`-prefixed names that
# `use <root> *` sweeps in through the `local` barrel (they are the same declarations under a second name, so
# they cannot be hidden separately and would clutter completions). Writing is idempotent: an existing file with
# the same content is left alone, and one with different content is kept unless `--force` is given.
@category env
export def init-local [
  --path (-p): path # The file to write (default: `local.nu` in the first user autoload directory)
  --force (-f) # Overwrite the file when its content differs
]: nothing -> record<path: path, action: string> {
  let file: path = $path | default { $nu.user-autoload-dirs | first | path join $AUTOLOAD_FILE } | path expand
  let text: string = [
    '# Written by `init-local` (nu-lib): the interactive command surface, local variants as bare names.'
    $"use ($ROOT | path join prelude.nu | to nuon) *"
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

# `export use` does not run the modules' `export-env` blocks; `loaders.nu` holds the guarded calls that do, and
# nothing else: `source-env` of a file also executes its top-level `use` statements (which *would* run the imported
# modules' environment blocks unguarded), so the loaders live in a file with no imports of their own.
export-env {
  const root: path = path self .
  source-env ($root | path join loaders.nu)
}
