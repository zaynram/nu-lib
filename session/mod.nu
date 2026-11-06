# Manage Zellij sessions: list, enter, switch, act on, run commands in, and tear down sessions.
#
# Adopted from the owner's `nupm+/session` module. Every command drives the `zellij` client. `list` parses
# `zellij list-sessions --no-formatting` (`<name> [Created <age> ago] [(<state>)]`). Inside a session
# `$env.ZELLIJ` and `$env.ZELLIJ_SESSION_NAME` identify it (`manage`); `enter` without a name falls back to
# `$env.ZELLIJ_AUTO_SESSION`. Opening files in an editor pane is the `edit` module's job (the original
# `session edit` is not carried over).

# ——— imports ——————————————————————————————————————————————————————————————————

use error

# ——— types ————————————————————————————————————————————————————————————————————

export type Session = record<name: string, age: duration, status: string>

# ——— helpers ——————————————————————————————————————————————————————————————————

# Raise `missing_dependency` unless the zellij client is on PATH. Every exported command runs it first, so a missing
# client is one error instead of a failed external call.
def need-client []: nothing -> nothing {
  if (which zellij | is-empty) {
    error raise 'zellij is not on PATH' ...{
      kind: missing_dependency
      advice: 'install zellij, or put its directory on PATH'
    }
  }
}

# Run the client with its output captured.
def --wrapped client [...args: string]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  ^zellij ...$args | complete
}

# The duration of an age as the client prints it (`1day 10h 41m 15s`: humantime units).
def into-age []: string -> duration {
  parse --regex r#'(?<n>\d+)(?<unit>[a-z]+)'#
  | each {|tok|
    let n: int = $tok.n | into int
    match $tok.unit {
      ns => ($n * 1ns)
      us => ($n * 1us)
      ms => ($n * 1ms)
      s => ($n * 1sec)
      m => ($n * 1min)
      h => ($n * 1hr)
      day | days => ($n * 1day)
      month | months => ($n * 2630016sec) # 30.44 days, as humantime defines it
      year | years => ($n * 31557600sec) # 365.25 days
      $unit => { error raise $"unknown age unit '($unit)'" --kind internal }
    }
  } | math sum
}

# The zellij configuration directory (`ZELLIJ_CONFIG_DIR`, else `$XDG_CONFIG_HOME/zellij`).
def config-dir []: nothing -> path {
  $env.ZELLIJ_CONFIG_DIR?
  | default { $env.XDG_CONFIG_HOME? | default ($nu.home-dir | path join .config) | path join zellij }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# List Zellij sessions with their age and status.
#
# Without a name pattern every session is listed; `status` is `active` or `exited` (resurrectable). No session at
# all gives an empty list.
@category shells
export def list [
  regex?: string@_names # Only sessions whose name matches this pattern
  --short (-s) # Return the names only
  --active (-a) # Only sessions that are still running
  --exited (-e) # Only sessions that have exited
]: nothing -> oneof<list<string>, list<Session>> {
  need-client
  let res: record = client list-sessions --no-formatting
  if $res.exit_code != 0 and $res.stderr =~ '(?i)no active zellij sessions' {
    return []
  } else if $res.exit_code != 0 {
    error raise 'zellij could not list its sessions' ...{
      kind: external_failure
      advice: ($res.stderr | str trim)
    }
  }
  $res.stdout
  | lines
  | parse '{name} [Created {age} ago]{status}'
  | update $.name { str trim }
  | update $.status { if ($in | str trim | str starts-with '(EXITED') { 'exited' } else { 'active' } }
  | where ($regex == null or $it.name =~ $regex)
  | where ($active == $exited or ($active and $it.status == 'active') or ($exited and $it.status == 'exited'))
  | if $short { get $.name } else { update $.age { into-age } }
}

# Kill and delete a Zellij session, or all of them.
#
# One client call does both: `delete-session --force` (`delete-all-sessions --yes --force` for all) kills a running
# session before deleting it and deletes an exited one as it is. A separate `kill-session` would race it: the kill
# returns before the server is gone, and a plain delete then refuses the session as still active.
@category shells
export def down [
  name?: string@_names # The session to kill and delete
  --all # Kill and delete every session (no confirmation prompt)
]: nothing -> nothing {
  need-client
  if $all {
    let res: record = client delete-all-sessions --yes --force
    if $res.exit_code != 0 {
      error raise 'zellij could not delete the sessions' ...{
        kind: external_failure
        advice: ($res.stderr | str trim)
      }
    }
  } else {
    let name: string = $name
      | default {
        error raise 'a session name is required without --all' ...{
          kind: invalid_argument
          advice: 'name the session to tear down, or pass --all'
        }
      }
    let res: record = client delete-session --force $name
    if $res.exit_code != 0 {
      error raise $"zellij could not delete the session '($name)'" ...{
        kind: external_failure
        advice: ($res.stderr | str trim)
      }
    }
  }
}

# Switch the current client to another Zellij session.
@category shells
export def --wrapped switch [
  name: string@_names # The session to switch to
  ...rest: string@_switch-args # Further arguments for `zellij action switch-session`
]: nothing -> nothing {
  need-client
  ^zellij action switch-session $name ...$rest
}

# Perform a `zellij action` in a session.
#
# The session is `--session`, else the one this shell runs in (`$env.ZELLIJ_SESSION_NAME`; inside a session the
# client needs no name at all). The flag has no short form: a `-s` anywhere on the line belongs to the action
# (`new-pane -s` starts the pane suspended).
@category shells
export def --wrapped manage [
  --session: string@_names # The session to act on
  ...rest: string@_actions # The action and its arguments
]: nothing -> nothing {
  need-client
  if $session != null {
    ^zellij --session=($session) action ...$rest
  } else if $env.ZELLIJ? != null {
    ^zellij action ...$rest
  } else if $env.ZELLIJ_SESSION_NAME? != null {
    ^zellij --session=($env.ZELLIJ_SESSION_NAME) action ...$rest
  } else {
    error raise 'no session name was given and this shell is not inside a Zellij session' ...{
      kind: invalid_argument
      advice: 'pass --session <name>, or run from inside the session'
    }
  }
}

# Run a command line in a new pane of the current Zellij session.
#
# The first argument is the command line (`'cargo build'`); the remaining arguments are options for
# `zellij run` (`--floating`, `--name build`), so a line that starts with a flag is an error. The command line is
# split on spaces with no quoting, so an argument that contains a space must come through the pipeline: a list
# piped in replaces the arguments split from the command line (`[-c 'a b'] | session exec sh`); the command line's
# first word stays the program.
@category shells
export def --wrapped exec [
  ...rest: string@_run-args # The command line, then `zellij run` options
]: oneof<nothing, list<string>> -> nothing {
  let piped: oneof<nothing, list<string>> = $in
  need-client
  let command: string = $rest | get --optional $.0
    | default {
      error raise 'a command line is required' ...{
        kind: invalid_argument
        advice: "`session exec 'cargo build' --floating`"
      }
    }
  if ($command | str starts-with '-') {
    error raise $"'($command)' is a flag, not a command line" ...{
      kind: invalid_argument
      advice: "put the command line first: `session exec 'cargo build' --floating`"
    }
  }
  let words: list<string> = $command | split row ' ' | where $it != ''
  if $words == [] {
    error raise $"the command line '($command)' names no program" ...{
      kind: invalid_argument
      advice: "`session exec 'cargo build' --floating`"
    }
  }
  let args: list<string> = $piped | default ($words | skip 1)
  ^zellij run ...($rest | skip 1) -- ($words | first) ...$args
}

# Enter a Zellij session, creating it when it does not exist.
#
# By default the client attaches (`zellij attach --create`); with `--attach=false` it starts a fresh session instead.
# Without a name, `$env.ZELLIJ_AUTO_SESSION` names the session when set; otherwise zellij attaches to the only
# session, creates one when none exists, and refuses when several exist. The further arguments go to
# `zellij attach`, or to `zellij` itself with `--attach=false`. A missing client is an error; the exit status of a
# client that started is not (a session killed from inside ends its client non-zero).
@category shells
export def --wrapped enter [
  name?: string@_names # The session to enter
  --attach = true # Attach to the session, creating it if needed; `--attach=false` starts a new session
  --layout (-l): string@_layouts # The layout of a newly created session
  ...rest: string@_attach-args # Further arguments for the client (`zellij attach`, or `zellij` with `--attach=false`)
]: nothing -> nothing {
  need-client
  let session: list<string> = [$name $env.ZELLIJ_AUTO_SESSION?] | compact | take 1
  let layout: list<string> = [$layout] | compact
  let args: list<string> = if $attach {
    [attach --create ...$session ...$rest ...($layout | each {|l| [options --default-layout $l] } | flatten)]
  } else {
    [...($session | each {|s| [--session $s] } | flatten) ...($layout | each {|l| [--new-session-with-layout $l] } | flatten) ...$rest]
  }
  # the client's exit status is not the caller's concern (a session killed from inside ends the client non-zero)
  try { ^zellij ...$args }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _names []: nothing -> list<string> {
  client list-sessions --short --no-formatting | get $.stdout | lines | str trim | where $it != ''
}

def _layouts []: nothing -> list<string> {
  glob --no-dir (config-dir | path join layouts '*.kdl') | path parse | get $.stem
}

# Completions of the client's own command line, through the active completer.
def --wrapped _proxy [...rest: string]: nothing -> list {
  $"zellij ($rest | str join ' ') " | commandline complete
}

def _actions []: nothing -> list { _proxy action }
def _switch-args []: nothing -> list { _proxy action switch-session }
def _run-args []: nothing -> list { _proxy run }
def _attach-args []: nothing -> list { _proxy attach }
