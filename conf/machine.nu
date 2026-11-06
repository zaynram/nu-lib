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
      error raise $"machine configuration file not found: '($named)'" --kind not_found --advice (
        'the file is named by --file or $env.NU_MACHINE_CONFIG; an empty NU_MACHINE_CONFIG means no file'
      )
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
      error raise $"conflicting machine configuration files: '($static)' and '($script)'" --kind conflict --advice (
        'keep one: machine.nuon for literal values, machine.nu when values must be computed'
      )
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
        $e | error raise $"machine configuration file is not valid nuon: '($file)'" --kind invalid_argument
      }
    }
    nu => {
      let child: record = with-env {NU_MACHINE_CONFIG: ''} {
        ^$nu.current-exe --no-config-file --include-path $ROOT --commands $"run `($file)` | to nuon" | complete
      }
      let stderr: string = $child.stderr | str trim
      if $child.exit_code != 0 {
        error raise $"machine configuration script failed \(exit ($child.exit_code)): '($file)'" --kind external_failure --advice $stderr
      }
      if $stderr != '' { print --stderr $stderr }
      try { $child.stdout | from nuon } catch {|e|
        $e | error raise $"machine configuration script printed something other than its record: '($file)'" --kind invalid_argument --advice (
          'the script must print nothing on stdout; report on stderr with `print --stderr`'
        )
      }
    }
    _ => {
      error raise $"unsupported machine configuration file \(expected .nuon or .nu): '($file)'" --kind invalid_argument
    }
  }
  if ($value | describe) !~ '^record' {
    error raise $"machine configuration must be a record, not ($value | describe): '($file)'" --kind invalid_argument
  }
  $value
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
    error raise $"invalid machine configuration \(($source)): ($failures.0.hint)" --kind invalid_argument --advice (
      $failures | each {|f| $"($f.rule): ($f.hint)" } | str join (char newline)
    )
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
  --verbose (-v)
  # Print the lookup target and which override file was used
]: nothing -> oneof<MachineConfig, error> {
  if $DEFAULT not-has $mode {
    error raise $"unsupported mode: '($mode)'" --kind invalid_argument --advice $"expected one of: ($MODE | str join ', ')"
  }
  if $strategy != null and $strategy not-in $STRATEGY {
    error raise $"unsupported strategy: '($strategy)'" --kind invalid_argument --advice $"expected one of: ($STRATEGY | str join ', ')"
  }
  if $file != null and $no_file { error raise '--file and --no-file are exclusive' --kind invalid_argument }
  let path: oneof<nothing, path> = if $no_file { null } else { override-path $file }
  let override: record = if $path == null { {} } else { load $path | check $path }
  let with: record = if $with == null { {} } else { $with | check '--with' }
  let strategy: string = $strategy | default $with.strategy? | default $override.strategy? | default 'overwrite'
  if $verbose {
    {mode: $mode host: ($host | default (sys host).hostname) os: $os strategy: $strategy override: ($path | default 'none')}
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
