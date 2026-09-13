# Various management-related utilities for working with system and provisioned packages.

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

alias get-job = do {|id: int| ignore | job list | where id == $id | first }

# Run the configured updates.
@category system
export def upgrade [
  --async (-a) # Spawn the update runner as a background job
  --silent (-s) # Do not return the results record after completion
]: oneof<record, nothing> -> record {
  if $async {
    job spawn --description=management-auto-upgrade {
      history upgrade --age
      | if $in == null or $in > 24hr { ignore | upgrade --silent }
    } | get-job $in
  } else {
    default {}
    | merge $REGISTRY
    | items {|bin args|
      if (which $bin | is-empty) {
        [{output: $"command not found: '($bin)'" success: false}]
      } else if ($args | describe) !~ '^list<list<' {
        let repr: string = $args | to nuon --serialize --raw-strings --no-commas
        let type: string = $args | describe
        [{output: $"invalid arguments: ($repr) \(($type))" success: false}]
      } else {
        $args | each {|rest|
          run-external $bin ...$rest out+err>|
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
  target: path@_targets # The log file to target
  --age (-a) # Return the duration since last write, if the log file exists
  --throw (-t) # Throw an error if the log file is missing
]: nothing -> oneof<record, nothing, duration> {
  if $LOG not-has $target { error make --unspanned $'invalid target: ($target)' }
  alias invoke = if $age { (date now) - (ls $in).0.modified } else { open $in }
  alias handle = if $throw { error make --unspanned 'no cached results found' }
  try { $LOG | get $target | invoke } catch { handle }
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

# ——— completions ————————————————————————————————————————————————————————————

def _targets []: nothing -> list { $LOG | columns }
