# Example machine override script for `conf machine-config` (the contract: _docs/machine-config.md).
#
# Install it as `($nu.default-config-dir)/machine.nu` and edit the values. `machine-config` runs it in a child
# `nu --no-config-file` with the library root as the include path (`run <file> | to nuon`), so library modules are
# available (`use env from-bash`, `use conf`, …) and `$NU_LIB_DIRS | first` is the library root. Only the returned
# record crosses back, as nuon: return strings and lists of strings. Stdout is the result, so report on stderr
# (`print --stderr`). A failing script fails `machine-config` (`conf::machine::load::external_failure`, with this stderr).
#
# Declarative values (XDG directories, `WORK`) can also come from `~/.config/environment.d/*.conf`, read without
# bash: `env parse ($nu.home-dir | path join .config environment.d)` (systemd's order and expansion rules).
#
# These are the owner's values for a laptop that runs Nushell both in WSL (Linux) and natively on Windows:
# - Linux, user scope: the XDG directories come from `~/.profile`, read through `env from-bash` with a minimal
#   PATH (the system directories and those of `bash` and `env`), so `binaries` gets the PATH entries the profile
#   adds and not everything the calling shell inherited; `modules`/`scripts` live under `WORK` (the environment,
#   else the profile), and tool directories under the data directory.
# - Linux, vendor scope: nupm's layout, from `NUPM_HOME` or next to Nushell's data directory.
# - Windows, user scope: the user directories map to `APPDATA`/`LOCALAPPDATA`.

use env from-bash

# `.profile` variables (the owner's `XDG_*_DIR` naming) and the user-scope keys they set.
const PROFILE_DIRS: record = {
  XDG_DATA_DIR: share
  XDG_CONFIG_DIR: config
  XDG_CACHE_DIR: cache
  XDG_STATE_DIR: state
}

# The user scope on Linux.
def linux-user []: nothing -> record {
  let base: list<path> = [/usr/bin /bin ...(which bash env | where type == external | get path | path dirname)]
  let sourced: record = with-env {PATH: ($base | uniq)} {
    from-bash --return=merge ($nu.home-dir | path join .profile)
  }
  let work: string = $env.work!?
    | default $sourced.WORK?
    | default { error make --unspanned 'WORK is not set (neither in the environment nor by ~/.profile)' }
  let dirs: record = $PROFILE_DIRS
    | record each {|var key| {$key: ($sourced | get --optional $var)} }
    | compact
  let share: path = $dirs.share? | default ($nu.data-dir | path dirname)
  let profile_path: list<string> = $sourced.PATH?
    | default []
    | if ($in | describe) == string { split row (char esep) } else { }
  $dirs | merge {
    scripts: [($work | path join bin) ($share | path join nupm scripts)]
    modules: [($NU_LIB_DIRS | first) ($work | path join ext)]
    binaries: ([
      /usr/bin
      ($nu.home-dir | path basename --replace linuxbrew/.linuxbrew/bin)
      ($share | path basename --replace bin)
      ($share | path join pnpm)
      ($share | path join ipex-llm-ollama)
      ...(glob --no-file --depth=3 $'($share)/**/bin')
      ...$profile_path
    ] | uniq)
  }
}

# The vendor scope on Linux: nupm's directories.
def linux-vendor []: nothing -> record {
  $env.NUPM_HOME? | default ($nu.data-dir | path basename --replace nupm) | {
    modules: ($in | path join modules)
    scripts: ($in | path join scripts)
    binaries: /usr/bin
  }
}

# The user scope on Windows.
def windows-user []: nothing -> record {
  $env | select $.APPDATA $.LOCALAPPDATA | {
    share: $in.APPDATA
    config: $in.APPDATA
    state: $in.LOCALAPPDATA
    cache: $in.LOCALAPPDATA
  }
}

# The override record for this machine, by the OS Nushell runs on.
def main []: nothing -> record {
  match $nu.os-info.name {
    linux => ({user: (linux-user) vendor: (linux-vendor)})
    windows => ({user: (windows-user)})
    _ => ({})
  }
}
