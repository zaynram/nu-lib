# Machine configuration: Nushell's directories as defaults, a per-machine override file, and a `--with` record.
#
# The library holds no host names. What differs between machines comes from `machine.nuon` (a record of literals)
# or `machine.nu` (a script whose `main` returns the record) in Nushell's config directory, from the file named by
# `$env.NU_MACHINE_CONFIG`, or from `--file`; `_docs/machine-config.md` is the contract and
# `_docs/examples/machine.nu` an example script.

# nu-lint-ignore-file: dispatch_with_subcommands

# ——— imports ——————————————————————————————————————————————————————————————————

use error
use validate

# ——— constants ————————————————————————————————————————————————————————————————

const ROOT: path = path self .. | path expand --strict
const MODE: list<string> = [user vendor]
const STRATEGY: list<string> = [overwrite prepend append]
# The override file in Nushell's config directory: `machine.nuon` (static) or `machine.nu` (a script).
const OVERRIDE: string = 'machine'
const FORMS: list<string> = [nuon nu]
# The cache of the configured override file's checked record: one nuon file in Nushell's cache directory, keyed by
# the file's path, modification time and size and by the running `nu` version (`_docs/hydration.md`).
const CACHE: path = $nu.cache-dir | path join nu-lib machine-override.nuon
# A script's cached record expires: the key cannot see the files and variables the script reads.
const CACHE_TTL: duration = 24hr
const WINDOWS_APPS: path = $nu.home-dir | path join AppData Local Microsoft WindowsApps
const DEFAULT: record = {
  user: {
    home: $nu.home-dir
    share: ($nu.data-dir | path dirname)
    cache: ($nu.cache-dir | path dirname)
    config: ($nu.default-config-dir | path dirname)
    state: ($nu.home-dir | path join .local state)
    autoload: ($nu.user-autoload-dirs | first)
    modules: [
      $ROOT
      ($nu.default-config-dir | path join modules)
      ($nu.data-dir | path basename --replace nupm/modules)
    ]
    binaries: [($nu.current-exe | path dirname) ($nu.home-dir | path join .local bin)]
    scripts: [($nu.default-config-dir | path join scripts) ($nu.data-dir | path basename --replace nupm/scripts)]
  }
  vendor : {
    autoload: ($nu.vendor-autoload-dirs | last)
    plugins: [($nu.data-dir | path join plugins (version).version) ($nu.current-exe | path dirname)]
    modules: ($nu.data-dir | path join modules)
    binaries: (if $nu.os-info.name == windows { $WINDOWS_APPS } else { '/usr/bin' })
    scripts: ($nu.data-dir | path join scripts)
  }
}

export const NU_PLUGIN_DIRS: list<path> = $DEFAULT.vendor.plugins
export const NU_LIB_DIRS: list<path> = [
  ...$DEFAULT.user.modules
  $DEFAULT.vendor.modules
]

# ——— typedefs —————————————————————————————————————————————————————————————————

type UserMachineConfig = record<home: path share: path cache: path config: path state: path autoload: path modules: list<path> binaries: list<path> scripts: list<path>>
type VendorMachineConfig = record<autoload: path, plugins: list<path>, modules: path, binaries: path scripts: path>
type MachineConfig = oneof<UserMachineConfig, VendorMachineConfig>

# ——— helpers ——————————————————————————————————————————————————————————————————

# Errors are raised where they occur so that their codes name the command (`conf::machine::load::invalid_argument`,
# see _docs/errors.md); _docs/machine-config.md lists them.

# The override file to use: `--file`, else `$env.NU_MACHINE_CONFIG` (a path; empty means none), else `machine.nuon`
# or `machine.nu` in Nushell's config directory (both present is a conflict). Null when there is none.
def override-path [file: oneof<nothing, path>]: nothing -> oneof<nothing, path> {
  let named: oneof<nothing, string> = $file | default $env.NU_MACHINE_CONFIG?
  if $named == '' { return null }
  if $named != null {
    if not ($named | path exists) {
      error raise $"override file not found: '($named)'" --with={
        kind: not_found
        help: (
          'the file is named by --file or $env.NU_MACHINE_CONFIG; an empty NU_MACHINE_CONFIG means no file'
        )
      }
    }
    return ($named | path expand)
  }
  let found: list<path> = $FORMS
    | each {|form| $nu.default-config-dir | path join $'($OVERRIDE).($form)' }
    | where ($it | path exists)
  match $found {
    [] => null
    [$one] => $one
    [$static $script] => {
      error raise $"both '($static)' and '($script)' exist" --with={
        kind: conflict
        help: (
          'keep one: machine.nuon for literal values, machine.nu when values must be computed'
        )
      }
    }
  }
}

# The record an override file holds. A `.nuon` is opened. A `.nu` runs in a child `nu` with the library on its
# include path and `NU_MACHINE_CONFIG` empty (so a script may `use conf` without loading itself again):
# `run <file> | to nuon`, whose stdout is the record and whose stderr is passed on.
def load [file: path]: nothing -> record {
  let value: any = match ($file | path parse | get extension) {
    nuon => {
      try { open $file } catch {|e|
        $e | error raise $"'($file)' is not valid nuon" --kind invalid_argument
      }
    }
    nu => {
      let child: record = with-env {NU_MACHINE_CONFIG: ''} {
        ^$nu.current-exe --no-config-file --include-path $ROOT --commands $"run `($file)` | to nuon" | complete
      }
      let stderr: string = $child.stderr | str trim
      if $child.exit_code != 0 {
        error raise $"override script '($file)' exited with code ($child.exit_code)" --with={
          kind: external_failure
          help: $stderr
        }
      }
      if $stderr != '' { print --stderr $stderr }
      try { $child.stdout | from nuon } catch {|e|
        $e | error raise $"override script '($file)' printed something other than its record" --with={
          kind: invalid_argument
          help: (
            'the script must print nothing on stdout; report on stderr with `print --stderr`'
          )
        }
      }
    }
    _ => {
      error raise $"not a .nuon or .nu file: '($file)'" --kind invalid_argument
    }
  }
  if ($value | describe) !~ '^record' {
    error raise $"'($file)' must be a record, not ($value | describe)" --kind invalid_argument
  }
  $value
}

# The cache key of an override file: its path, the modification time (ns) and size of the file itself (a symlink
# is followed), the library root and the `nu` version.
def cache-key [file: path]: nothing -> record {
  let entry: record = ls --directory ($file | path expand) | first
  {file: $file modified: ($entry.modified | into int) size: ($entry.size | into int) root: $ROOT nu: (version).version}
}

# The checked record of the configured override file, served from the cache when the key matches and, for a script,
# the record is younger than a day (a `.nu` override otherwise runs a child `nu`, and either form is validated, on
# every call), else loaded, checked and cached.
# `cache` says what happened: `hit`, `miss` (the cache was rewritten) or `off` (`--no-cache`: loaded and rewritten).
def override-record [file: path --no-cache]: nothing -> record<value: record, cache: string> {
  let key: record = cache-key $file
  let cached: any = if $no_cache { null } else { try { open $CACHE } catch { null } }
  let hit: bool = if ($cached | describe) =~ '^record' and $cached.key? == $key {
    # A static file is its own record; a script's record is trusted for a day.
    ($file | path parse | get extension) == 'nuon' or (($cached.at? | describe) == 'datetime' and (date now) - $cached.at < $CACHE_TTL)
  } else { false }
  if $hit { return {value: $cached.value cache: hit} }
  let value: record = load $file | check $file
  # A cache that cannot be written is not an error: the next call loads the file again.
  try {
    mkdir ($CACHE | path dirname)
    let tmp: path = $"($CACHE).($nu.pid)"
    {key: $key at: (date now) value: $value} | to nuon | save --force $tmp
    mv --force $tmp $CACHE
  } catch { null }
  {value: $value cache: (if $no_cache { 'off' } else { 'miss' })}
}

# The rules an override must satisfy: an optional `strategy`, and under `user`/`vendor` the keys of that scope, typed
# like its defaults (paths are strings: the file holds literals, or values that crossed `to nuon`).
def rules []: nothing -> table {
  $DEFAULT
  | items {|mode defaults|
    $defaults
    | items {|key value|
      {path: ([$mode $key] | into cell-path) type: (if ($value | describe) =~ '^list' { 'list<string>' } else { 'string' })}
    }
    | prepend {path: ([$mode] | into cell-path) type: record}
  }
  | flatten
  | prepend {path: $.strategy type: string enum: $STRATEGY}
}

# Validate an override (a file's record, or `--with`); a null value counts as unset. Fails naming every violation.
def check [source: string]: record -> record {
  let value: record = $in
    | record each {|key part| {$key: (if ($part | describe) =~ '^record' { $part | compact } else { $part })} }
  let failures: table = $value | validate rules (rules) --strict --colors=false --return=table
  if $failures != [] {
    error raise $"invalid '($source)': ($failures.0.hint)" --with={
      kind: invalid_argument
      help: (
        $failures | each {|f| $"($f.rule): ($f.hint)" } | str join (char newline)
      )
    }
  }
  $value
}

# ——— scripts ——————————————————————————————————————————————————————————————————

# Return the machine configuration of a scope: the defaults, the override file's values, then `--with`.
#
# The defaults derive from Nushell's directories. The override file (`machine.nuon` or `machine.nu` in Nushell's
# config directory, `$env.NU_MACHINE_CONFIG`, or `--file`; see _docs/machine-config.md) and the `--with` record have
# the same shape, `{user: {…} vendor: {…} strategy: …}` with every key optional, and merge over the defaults in that
# order; `--strategy` decides how list values combine (default: the record's `strategy`, else overwrite). The library
# holds no host names: `--host` only labels the lookup (`--verbose`), and `--os` picks the OS-dependent defaults
# (the vendor binaries), for inspection and tests.
def main [
  mode: string@$MODE = user
  # The scope to return: user or vendor
  --host: string
  # The hostname the configuration is for (defaults to `hostname`); no default depends on it
  --os (-o): string = $nu.os-info.name
  # The OS the defaults are for
  --strategy (-s): string@$STRATEGY
  # How override list values combine with the defaults: overwrite, prepend or append
  --with (-w): record
  # Values merged last, in the override file's shape
  --file (-f): path
  # Use this override file instead of the configured one
  --no-file
  # Ignore any override file: the defaults and `--with` only
  --no-cache
  # Load and check the configured override file even when its cached record is current (the cache is rewritten)
  --verbose (-v)
  # Print the lookup target, which override file was used and whether its record came from the cache
]: nothing -> oneof<MachineConfig, error> {
  if $DEFAULT not-has $mode {
    error raise $"unsupported mode: '($mode)'" --with={
      kind: invalid_argument
      help: $"expected one of: ($MODE | str join ', ')"
    }
  }
  if $strategy != null and $strategy not-in $STRATEGY {
    error raise $"unsupported strategy: '($strategy)'" --with={
      kind: invalid_argument
      help: $"expected one of: ($STRATEGY | str join ', ')"
    }
  }
  if $file != null and $no_file {
    error raise '--file and --no-file are exclusive' --kind invalid_argument
  }
  let path: oneof<nothing, path> = if $no_file { null } else { override-path $file }
  # `--file` names an ad-hoc file: it is not cached (the cache holds the configured file's record).
  let loaded: record = if $path == null {
    {value: {} cache: none}
  } else if $file != null {
    {value: (load $path | check $path) cache: off}
  } else {
    override-record $path --no-cache=$no_cache
  }
  let override: record = $loaded.value
  let with: record = if $with == null { {} } else { $with | check '--with' }
  let strategy: string = $strategy | default $with.strategy? | default $override.strategy? | default 'overwrite'
  if $verbose {
    {mode: $mode host: ($host | default (sys host).hostname) os: $os strategy: $strategy override: ($path | default 'none') cache: $loaded.cache}
    | transpose k v
    | format pattern '{k} = {v}'
    | each {|line| print $line }
    | ignore
  }
  $DEFAULT
  | get $mode
  | if $mode == vendor { update binaries (if $os == windows { $WINDOWS_APPS } else { '/usr/bin' }) } else { }
  | merge deep --strategy=$strategy ($override | get --optional $mode | default {})
  | merge deep --strategy=$strategy ($with | get --optional $mode | default {})
  | record each {|key value| {$key: (if ($value | describe) =~ '^list' { $value | uniq } else { $value })} }
}

export alias machine-config = main
