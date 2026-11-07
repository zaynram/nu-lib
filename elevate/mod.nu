# Utilities to ease working with elevated privileges in Nushell.

# ——— imports ——————————————————————————————————————————————————————————————————

use command attempt

# ——— constants ————————————————————————————————————————————————————————————————

const UNAUTHORIZED: string = '(?i)\b(401|403|unauthori[sz]ed|not (logged in|authenticated)|auth login)\b'

# ——— definitions ——————————————————————————————————————————————————————————————

# Elevate the current shell process.
#
# Replaces the current process with `sudo <binary> [--login] ...rest`, where `binary` is `--binary` (default: the
# running `nu`). Every other argument, flags included, is passed to that `nu` (`elevate -c 'whoami'`); only
# `--binary`/`-b` and `--login`/`-l` are taken by this command, wherever they appear.
@category system
export def --env --wrapped main [
  --binary (-b): path = $nu.current-exe
  # Path to a `nu` binary to use
  --login (-l) = $nu.is-login
  # Whether to elevate as a login shell (default: whether this shell is one); takes a value: `--login=false`
  ...rest: string
  # Arguments to pass to the `nu` invocation
]: nothing -> nothing {
  exec sudo $binary ...(if $login { [--login] } else { [] }) ...$rest
}

# Run a shell command in an elevated context.
#
# Runs `sudo <shell> -c "<rest joined with spaces>"`, or `sudo <shell> <script> ...rest` with `--script`, and
# returns its output. Any shell that accepts `-c` works. The pipeline input is forwarded to the shell's stdin
# unless `--stdin=false`; a `nu` shell also gets `--stdin` so the command can read it as `$in`. The flags have
# no short forms, so the command's own `-s`/`-i`/`-S` flags pass through; the long names `--shell`, `--script`
# and `--stdin` always belong to this command, wherever they appear on the line, so a command that needs one of
# them must be wrapped in a quoted string (`--shell sh -c 'tool --stdin'`).
@category system
export def --env --wrapped sh [
  --shell: path = $nu.current-exe
  # Path to a shell executable to use for the invocation
  --script: path
  # Run this script in an elevated context with the spread arguments passed through
  --stdin = true
  # Whether to forward the pipeline input passed to this function; takes a value: `--stdin=false`
  ...rest: string
  # Arguments to pass with the invocation
]: oneof<nothing, string> -> oneof<nothing, any> {
  let input: oneof<nothing, string> = if $stdin { $in }
  let command: list<string> = if $script != null {
    [($script | path expand --strict) ...$rest]
  } else {
    [-c ($rest | str join (char space))]
  }
  let nu_stdin: list<string> = if $stdin and ($shell | path parse | get $.stem) == nu { [--stdin] } else { [] }
  $input | ^sudo $shell ...$nu_stdin ...$command
}

# Run an external command and return its stdout.
#
# With arguments (or `--strict`) a non-zero exit raises the captured output; without them the merged stdout and
# stderr is returned whatever the exit code. On an auth failure (output matching `--pattern`) in an interactive
# session, `--login` runs once and the command is retried. The flags have no short forms, so the command's own
# `-l`/`-s` flags pass through; the long names `--login`, `--pattern` and `--strict` always belong to this
# command, wherever they appear on the line, so a command that needs one of them must be wrapped
# (`with-auth sh -c 'tool --strict'`).
@category system
export def --wrapped with-auth [
  name: string
  # The name of the external command to run
  --login: closure
  # Interactive login, e.g. `{|| ^td auth login }` or `{|| ^gh auth login }`
  --pattern: string = $UNAUTHORIZED
  # Regex identifying an auth failure in the command's stdout or stderr
  --strict
  # Check the `exit_code` even when no arguments are provided
  ...rest: string
  # The arguments to pass to the external command
]: nothing -> string {
  let check: bool = $strict or ($rest | is-not-empty)
  alias execute = attempt --check=$check --merge=(not $check) $name ...$rest
  try { execute } catch {|err|
    if $nu.is-interactive and $login != null and ($err.details.help? | default '') =~ $pattern {
      do $login
      execute
    } else {
      # not an auth failure: `attempt`'s own error (the exit code, with the output as help) is re-raised as it is
      $err.raw
    }
  } | if not $check { get $.stdout } else { }
}
