# Package management for the system and provisioned tooling: upgrades, apt, plugins and the Nushell binary.
#
# `bump-nu` (in `nightly.nu`) installs the latest Nushell nightly build. It smoke-tests the new `nu` before
# installing it (it must report its version and load this library), keeps every replaced file as `<name>.previous`,
# and `--rollback` puts the previous build back. `upgrade` reinstalls the nightly through the same bump when
# `cargo install-update` has written a stable `nu` over it, and reports a refused bump under `nu` in its results.

use conf/machine.nu [ machine-config ]
use error
use style
export use nightly.nu [ bump-nu ]

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
#
# Runs every argument set of `REGISTRY` (merged with the piped record, whose entries win) for each binary on
# PATH, after putting the user scope's binary directories on PATH. Results are saved to `LOG.upgrade` and
# returned as `{<binary>: [{output, success}]}`; a missing binary or malformed arguments become a failed entry.
# When the `cargo` run has left a stable `nu` on disk (`cargo install-update --all` overwrites a nightly build),
# `bump-nu --yes` reinstalls the latest nightly through its smoke test, and the outcome is one more entry, `nu`:
# `{output success: true}` naming the installed version, or `{output success: false}` with the error when the bump
# failed or refused the build — the stable `nu` then stays, and the entry says so.
# With `--async`, a background job runs the upgrade when the last one is over a day old, and the job's record
# is returned.
@category system
export def upgrade [
  --async (-a) # Spawn the update runner as a background job
  --silent (-s) # Do not return the results record after completion
  --system # Include the system package manager (needs a sudo prompt, so not with `--async`)
]: oneof<record, nothing> -> oneof<record, nothing> {
  let input: oneof<nothing, record> = $in
  if $async {
    if $system {
      error raise '`--system` cannot run in the background' ...{
        kind: invalid_argument
        advice: 'sudo needs a prompt: run `pman upgrade --system` in the foreground'
      }
    }
    job spawn --description=pkg-auto-upgrade {
      history upgrade --age
      | if $in == null or $in > 24hr { ignore | upgrade --silent }
    } | get-job $in
  } else {
    use std/util "path add"
    path add ...(machine-config user).binaries
    # The owner's tool environment names the data dir `XDG_DATA_DIR` (see _docs/examples/machine.nu); children expect it.
    if $env not-has XDG_DATA_DIR { $env.XDG_DATA_DIR = $nu.home-dir | path join .local share }
    let base: record = $REGISTRY | if $system { merge $SYSTEM } else { }
    match ($input | describe | str replace --regex '<.+' '') {
      nothing => $base
      record => ($base | merge $input)
    } | items {|bin args|
      let cmd: list<string> = if $SYSTEM has $bin { [sudo $bin] } else { [$bin] }
      if (which $bin | is-empty) {
        [{output: $"command not found: '($bin)'" success: false}]
      } else if ($args | describe) !~ '^list<list<' {
        let repr: string = $args | to nuon --serialize --raw-strings --no-commas
        let type: string = $args | describe
        [{output: $"invalid arguments: ($repr) \(($type))" success: false}]
      } else {
        # Sequential and in order: a binary's argument sets depend on each other (`apt-get update` before
        # `upgrade`) and often share a lock.
        $args | each {|rest|
          let name: string = $cmd | first
          let rest: list = ($cmd | skip) ++ $rest
          ^$name ...$rest | complete | if $in.exit_code == 0 {
              rename --column={stdout: output}
              | insert $.success true
            } else {
              rename --column={stderr: output}
              | insert $.success false
            } | select $.output $.success
        }
      } | {$bin: $in}
    } | into record
    | if $in has cargo { merge (restore-nightly) } else { }
    | try {
      let res: record = $in
      mkdir $nu.cache-dir
      $res | save --force $LOG.upgrade
      if not $silent { $res }
    } catch {|e|
      $e | error raise $"could not save the upgrade results to '($LOG.upgrade)'" --kind io
    }
  }
}

# Reinstall the nightly when the installed `nu` is no longer one (`cargo install-update --all` writes the stable
# build over it): `{nu: [{output success}]}` with the bump's outcome, or `{}` while the installed `nu` is a nightly.
# The installed binary is asked, not the running one: the running shell is still the nightly that was overwritten.
def restore-nightly []: nothing -> record {
  let installed: string = try { ^$nu.current-exe --version | complete | get stdout | str trim } catch { '' }
  if $installed =~ nightly { return {} }
  let stable: string = if $installed == '' { 'a nu that does not run' } else { $'nu ($installed)' }
  let outcome: record = try {
    let bumped: record = bump-nu --yes
    {output: $"installed nu ($bumped.latest) over ($stable)" success: true}
  } catch {|e|
    # The error, its cause (a chained download error, say) and its advice.
    let reason: string = [$e.msg $e.details?.inner?.0?.msg?] | compact --empty | str join ': '
    let advice: string = $e.details?.help? | default ''
    {output: ([$"($stable) stays: ($reason)" $advice] | compact --empty | str join (char newline)) success: false}
  }
  {nu: [$outcome]}
}

# Show the results from the latest update run.
@category system
export def history [
  target: string@_targets # The log file to target
  --age (-a) # Return the duration since last write, if the log file exists
  --throw (-t) # Throw an error if the log file is missing
]: nothing -> oneof<record, nothing, duration> {
  if $LOG not-has $target {
    error raise $"unknown target '($target)'" ...{
      kind: invalid_argument
      advice: $"targets: ($LOG | columns | str join ', ')"
    }
  }
  alias invoke = if $age { (date now) - (ls $in).0.modified } else { open $in }
  try { $LOG | get $target | invoke } catch {|e|
    if $throw {
      $e | error raise $"no cached results found for '($target)'" ...{
        kind: not_found
        advice: $"nothing has written '($LOG | get $target)' yet"
      }
    }
  }
}

# Install system packages with apt.
@category system
export def install [
  ...names: string@_apt # Names of the packages to install
]: nothing -> nothing {
  if ($names | is-empty) { error raise 'no packages were provided' --kind invalid_argument }
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
#
# A plugin that fails to load again is reported on stderr and left as it is (re-add it with `plugin add`).
@category plugin
export def --env reload-plugins [
  ...names: string@_plugin-names
  # Only reload plugins matching one of these names, if provided
]: nothing -> nothing {
  let queue: table = plugin list | if $names == [] { } else { where name in $names }
  for row in $queue {
    try { plugin stop $row.name; plugin rm $row.name }
    try {
      plugin add $row.filename
      print ($'added ($row.name)' | style paint green)
    } catch {|e|
      print --stderr ($'could not re-add ($row.name) from ($row.filename): ($e.msg)' | style paint red)
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _targets []: nothing -> list { $LOG | columns }

# Complete through the shell's external completer as the equivalent `sudo apt-get` line.
def _apt [buffer: string]: nothing -> oneof<list, table> {
  let line: string = $buffer
    | split row (char space)
    | skip while $it not-in [apt install remove]
    | if $in.0? == apt { skip } else { }
    | prepend [sudo apt-get]
    | str join (char space)
  $line | commandline complete --type=command
}

def _plugin-names []: nothing -> table {
  plugin list
  | select name filename version
  | insert description {|row|
    $'[($row.version)] ($row.filename)'
  } | rename --column={name: value}
  | select value description
}
