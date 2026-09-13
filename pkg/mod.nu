# Package management for the system and provisioned tooling: upgrades, apt, plugins and the Nushell binary.
# nu-lint-ignore-file: unhandled_external_error

use ../mod.nu NU_LIB_DIRS
use ../util null-device
export use nightly-toolkit get-latest-nightly-build

# Ephemeral log file holding the output of the latest run.
export const LOG: record = {
  upgrade: ($nu.cache-dir | path join update_results.nuon)
}

# Mapping of binaries to a list of argument sets (each representing a separate call).
export const REGISTRY: record = {
  rustup: [[upgrade]]
  dprint: [[upgrade]]
  brew: [[upgrade]]
  claude: [[upgrade]]
  cargo: [[install-update --all]]
  pipx: [[upgrade-all]]
  pixi: [[self-update] [global update]]
  bun: [[upgrade --canary] [--global update]]
}

# System package manager calls, run through `sudo` and included by `upgrade --system`.
const SYSTEM: record = {
  apt-get: [[update --yes] [upgrade --yes]]
}

alias get-job = do {|id: int| ignore | job list | where id == $id | first }
alias apt-get = sudo apt-get

# Run the configured updates.
@category system
export def upgrade [
  --async (-a) # Spawn the update runner as a background job
  --silent (-s) # Do not return the results record after completion
  --system # Include the system package manager (needs a sudo prompt, so not with `--async`)
]: oneof<record, nothing> -> record {
  if $async {
    if $system { error make --unspanned '`--system` cannot run in the background: sudo needs a prompt' }
    job spawn --description=pkg-auto-upgrade {
      history upgrade --age
      | if $in == null or $in > 24hr { ignore | upgrade --silent }
    } | get-job $in
  } else {
    default {}
    | merge $REGISTRY
    | merge (if $system { $SYSTEM } else { {} })
    | items {|bin args|
      let cmd: list<string> = if $SYSTEM has $bin { [sudo $bin] } else { [$bin] }
      if (which $bin | is-empty) {
        [{output: $"command not found: '($bin)'" success: false}]
      } else if ($args | describe) !~ '^list<list<' {
        let repr: string = $args | to nuon --serialize --raw-strings --no-commas
        let type: string = $args | describe
        [{output: $"invalid arguments: ($repr) \(($type))" success: false}]
      } else {
        $args | each {|rest|
          run-external ...$cmd ...$rest out+err>|
          | complete
          | reject --optional stderr
          | rename --column={stdout: output exit_code: success}
          | update success { $in == 0 }
        }
      } | {$bin: $in}
    } | into record
    | try {
      let res: record = $in
      mkdir $nu.cache-dir
      $res | save --force $LOG.upgrade
      if not $silent { $res }
    } catch {
      error make --unspanned
    }
  }
}

# Show the results from the latest update run.
@category system
export def history [
  target: string@_targets # The log file to target
  --age (-a) # Return the duration since last write, if the log file exists
  --throw (-t) # Throw an error if the log file is missing
]: nothing -> oneof<record, nothing, duration> {
  if $LOG not-has $target { error make --unspanned $'invalid target: ($target)' }
  alias invoke = if $age { (date now) - (ls $in).0.modified } else { open $in }
  alias handle = if $throw { error make --unspanned 'no cached results found' }
  try { $LOG | get $target | invoke } catch { handle }
}

# Install system packages with apt.
@category system
export def install [
  ...names: string@_apt # Names of the packages to install
]: nothing -> nothing {
  if ($names | is-empty) { error make --unspanned 'no packages were provided' }
  apt-get install --yes ...$names
}

# Remove system packages with apt, then clean up unused packages and the cache.
@category system
export def remove [
  ...names: string@_apt # Names of the packages to remove
]: nothing -> nothing {
  if ($names | is-not-empty) { apt-get remove --yes ...$names }
  clean
}

# Remove unused system packages and clean the apt cache.
@category system
export def clean []: nothing -> nothing {
  apt-get autoremove --yes
  apt-get autoclean --yes
}

# Pass a command through to `apt-get` with elevated privileges.
@category system
export def --wrapped apt [
  ...rest: string@_apt # Arguments for `apt-get`
]: nothing -> nothing {
  apt-get ...$rest
}

# Reload all plugins to ensure latest version is loaded.
@category plugin
export def --env reload-plugins []: nothing -> nothing {
  for row in (plugin list --engine) {
    try { plugin stop $row.name; plugin rm $row.name }
    try {
      plugin add $row.filename
      print $'(ansi green)added ($row.name)(ansi rst)'
    } catch {
      cargo uninstall ($row.filename | path basename) out+err>| complete
      print --stderr $'(ansi red)uninstalled ($row.name)(ansi rst)'
    }
  }
}

# Update the Nushell binary and reload all plugin binaries.
@category system
export def --env bump-nu []: nothing -> nothing { get-latest-nightly-build; reload-plugins }

# ——— completions ——————————————————————————————————————————————————————————————

def _targets []: nothing -> list { $LOG | columns }

# Complete through the shell's external completer as the equivalent `sudo apt-get` line.
def _apt [buffer: string]: nothing -> oneof<list, table> {
  let line: string = $buffer
    | split row (char space)
    | skip while { $in not-in [apt install remove] }
    | if $in.0? == apt { skip } else { }
    | prepend [sudo apt-get]
    | str join (char space)
  $env.config.completions.external.completer? | if $in == null { [] } else { do $in $line }
}
