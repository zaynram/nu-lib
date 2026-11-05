#!/usr/bin/env -S nu --no-std-lib --no-config-file --stdin

# nu-lint-ignore-file: dispatch_with_subcommands

# ——— constants ————————————————————————————————————————————————————————————————

const ROOT: path = path self . | path expand --strict
const MODE: list<string> = [user vendor]
const STRATEGY: list<string> = [overwrite prepend append]
const DEFAULT: record = {
  user: {
    home: $nu.home-dir
    share: ($nu.data-dir | path dirname)
    cache: ($nu.cache-dir | path dirname)
    config: ($nu.default-config-dir | path dirname)
    state: ($nu.cache-dir | path dirname)
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
    binaries: (if $nu.os-info.name == windows { $nu.home-dir | path join AppData Local Microsoft WindowsApps } else { '/usr/bin' })
    scripts: ($nu.data-dir | path join scripts)
  }
}

export const NU_PLUGIN_DIRS: list<path> = $DEFAULT.vendor.plugins
export const NU_LIB_DIRS: list<path> = [
  ...$DEFAULT.user.modules
  $DEFAULT.vendor.modules
]

# ——— helpers ——————————————————————————————————————————————————————————————————

# ——— typedefs —————————————————————————————————————————————————————————————————

type UserMachineConfig = record<home: path share: path cache: path config: path state: path autoload: path modules: list<path> binaries: list<path> scripts: list<path>>
type VendorMachineConfig = record<autoload: path, plugins: list<path>, modules: path, binaries: path scripts: path>
type MachineConfig = oneof<UserMachineConfig, VendorMachineConfig>

# ——— scripts ——————————————————————————————————————————————————————————————————

# Return the machine configuration based on the current platform and environment.
#
# The configuration target can be overridden manually with flags.
# Custom environments can be used for testing purposes by piping a record in.
def main [
  mode: string@$MODE = user
  # Return the machine configuration for this space
  --host (-h): string
  # Override the hostname to return the variables for (defaults to `hostname`)
  --os (-o): string = $nu.os-info.name
  # Override the OS (platform) to return variables for
  --strategy (-s): string@$STRATEGY
  # Strategy for merging machine-specific values into the defaults
  --with (-w): record
  # Gather machine configuration values with this record as a temporary environment
  --verbose (-v)
  # Print information to the console as the configuration is built
# ]: nothing -> oneof<record, error> {
  ]: nothing -> oneof<MachineConfig, error> {
  if $DEFAULT not-has $mode { error make --unspanned $"unsupported mode: '($mode)'" }
  if $with != null { return (with-env $with {|| main $mode --host=$host --os=$os --strategy=$strategy }) }
  let meta: record = {mode: $mode host: $host os: $os}
    | default (sys host).hostname $.host
    | default $nu.os-info.name $.os
  if $verbose { $meta | transpose k v | format pattern '{k} = {v}' | print }
  let machine: record = match $meta {
    {mode: user host: ZR-XPS14 os: linux} => {||
      let profile: path = $nu.home-dir | path join .profile
      use /work/ext/bash-env
      bash-env --return=merge $profile
      | match ($in.path!? | describe) {
        nothing | list<any> | list<string> => ()
        string => (update $.path! ($in.path! | split row (char esep)) | rename --column={PATH: binaries})
      } | select ...($in | columns | where $it starts-with XDG)
      | rename --block={ str replace --regex 'XDG_(\w+)_DIR' '$1' | str lowercase }
      | insert $.scripts [($env.work! | path join bin) ($in.data | path join nupm scripts)]
      | insert $.modules [$ROOT ($env.work! | path join ext)]
      | insert $.binaries [
        $DEFAULT.vendor.binaries
        ($nu.home-dir | path basename --replace linuxbrew/.linuxbrew/bin)
        ($in.data | path basename --replace bin)
        ($in.data | path join pnpm)
        ($in.data | path join ipex-llm-ollama)
        ...(glob --no-file --depth=3 $'($in.data)/**/bin')
      ]
    }
    {mode: user host: ZR-XPS14 os: windows} => {||
      $env | select $.APPDATA $.LOCALAPPDATA | {
        share: $in.APPDATA
        config: $in.APPDATA
        state: $in.LOCALAPPDATA
        cache: $in.LOCALAPPDATA
      }
    }
    {mode: vendor host: ZR-XPS14 os: linux} => {||
      $env.NUPM_HOME? | default ($nu.data-dir | path basename --replace nupm) | {
        modules: ($in | path join modules)
        scripts: ($in | path join scripts)
        binaries: /usr/bin/
      }
    }
    _ => (return ($DEFAULT | get $mode))
  } | do --env --ignore-errors $in | default {}
  $DEFAULT | get $mode | merge deep --strategy=overwrite $machine | compact
}

export alias machine-config = main
