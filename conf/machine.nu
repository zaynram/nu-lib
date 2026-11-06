#!/usr/bin/env -S nu --no-std-lib --no-config-file --stdin

# nu-lint-ignore-file: dispatch_with_subcommands

# ——— imports ——————————————————————————————————————————————————————————————————

use ../bash-env

# ——— constants ————————————————————————————————————————————————————————————————

const ROOT: path = path self .. | path expand --strict
const MODE: list<string> = [user vendor]
const STRATEGY: list<string> = [overwrite prepend append]
# `.profile` variables (the owner's `XDG_*_DIR` naming) and the user-scope keys they set.
const PROFILE_DIRS: record = {
  XDG_DATA_DIR: share
  XDG_CONFIG_DIR: config
  XDG_CACHE_DIR: cache
  XDG_STATE_DIR: state
}
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
# The defaults derive from Nushell's directories; a known host/OS/mode combination merges its own values over
# them (`--strategy` decides how list values combine). When a host branch fails (e.g. a missing `~/.profile` or
# an unset variable), the cause is printed on stderr and the defaults are returned. The ZR-XPS14 Linux branch
# sources `~/.profile` with a minimal PATH, so `binaries` gets the PATH entries the profile adds (and that base,
# `/usr/bin`, `/bin` and the directories of `bash` and `jq`), not the PATH of the calling shell. The target can be
# overridden with `--host`/`--os`, and `--with` runs the lookup under a temporary environment (handy for tests).
def main [
  mode: string@$MODE = user
  # Return the machine configuration for this space
  --host (-h): string
  # Override the hostname to return the variables for (defaults to `hostname`)
  --os (-o): string = $nu.os-info.name
  # Override the OS (platform) to return variables for
  --strategy (-s): string@$STRATEGY = overwrite
  # How machine-specific list values combine with the defaults: overwrite, prepend or append
  --with (-w): record
  # Gather machine configuration values with this record as a temporary environment
  --verbose (-v)
  # Print information to the console as the configuration is built
]: nothing -> oneof<MachineConfig, error> {
  if $DEFAULT not-has $mode { error make --unspanned $"unsupported mode: '($mode)'" }
  if $strategy not-in $STRATEGY {
    error make --unspanned $"unsupported strategy: '($strategy)' \(expected one of: ($STRATEGY | str join ', '))"
  }
  if $with != null {
    return (with-env $with {|| main $mode --host=$host --os=$os --strategy=$strategy --verbose=$verbose })
  }
  let meta: record = {mode: $mode host: $host os: $os}
    | default (sys host).hostname $.host
    | default $nu.os-info.name $.os
  if $verbose { $meta | transpose k v | format pattern '{k} = {v}' | print }
  let branch: oneof<nothing, closure> = match $meta {
    {mode: user host: ZR-XPS14 os: linux} => {||
      # Sourced with a minimal PATH (the system directories and those holding `bash` and `jq`, which bash-env
      # runs), so the PATH the profile exports holds its own entries, not everything this shell inherited.
      let base: list<path> = [/usr/bin /bin ...(which bash jq | where type == external | get path | path dirname)]
      let sourced: record = with-env {PATH: ($base | uniq)} {
        bash-env --return=merge ($nu.home-dir | path join .profile)
      }
      let work: oneof<nothing, string> = $env.work!? | default $sourced.WORK?
      if $work == null { error make --unspanned 'WORK is not set (neither in the environment nor by ~/.profile)' }
      let dirs: record = $PROFILE_DIRS
        | items {|var key| {$key: ($sourced | get --optional $var)} }
        | into record
        | compact
      let share: path = $dirs.share? | default $DEFAULT.user.share
      let profile_path: list<string> = $sourced.PATH?
        | default []
        | if ($in | describe) == string { split row (char esep) } else { }
      $dirs | merge {
        scripts: [($work | path join bin) ($share | path join nupm scripts)]
        modules: [$ROOT ($work | path join ext)]
        binaries: ([
          $DEFAULT.vendor.binaries
          ($nu.home-dir | path basename --replace linuxbrew/.linuxbrew/bin)
          ($share | path basename --replace bin)
          ($share | path join pnpm)
          ($share | path join ipex-llm-ollama)
          ...(glob --no-file --depth=3 $'($share)/**/bin')
          ...$profile_path
        ] | uniq)
      }
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
        binaries: /usr/bin
      }
    }
    _ => null
  }
  let machine: record = if $branch == null { {} } else {
    try { do $branch | default {} } catch {|e|
      let target: string = $meta | values | str join '/'
      print --stderr $"(ansi yellow)machine-config: the ($target) configuration failed, using the defaults: ($e.msg)(ansi reset)"
      {}
    }
  }
  $DEFAULT
  | get $mode
  | merge deep --strategy=$strategy $machine
  | compact
  | items {|key value| {$key: (if ($value | describe) =~ '^list' { $value | uniq } else { $value })} }
  | into record
}

export alias machine-config = main
