# Utilities to ease working with elevated privilges in Nushell.

# ——— imports ——————————————————————————————————————————————————————————————————

use ../util attempt

# ——— constants ————————————————————————————————————————————————————————————————

const UNAUTHORIZED: string = '(?i)\b(401|403|unauthori[sz]ed|not (logged in|authenticated)|auth login)\b'

# ——— definitions ——————————————————————————————————————————————————————————————

# Elevate the current shell process.
@category system
export def --env --wrapped main [
  binary: path = $nu.current-exe
  # Path to a `nu` binary to use
  --login (-l) = $nu.is-login
  # Whether to elevate as a login shell process
  ...rest: string
  # Arguments to pass to the `nu` invocation
]: nothing -> nothing {
  sudo exec $nu.current-exe ...(if $login { '--login' } | append $rest)
}

# Run a shell command in an elevated context.
@category system
export def --env --wrapped sh [
  --shell (-S): path = $nu.current-exe
  # Path to a shell executable to use for the invocation
  --script (-s): path
  # Run this script in an elevated context with the spread arguments passed through
  --stdin (-i) = true
  # Whether to forward the pipeline input passed to this function.
  ...rest: string
  # Arguments to pass with the invocation
]: oneof<nothing, string> -> oneof<nothing, any> {
  let input: oneof<nothing, string> = if $stdin { }
  let args: list = match (if $script != null { $script | path expand --strict }) {
    null => [-c ($rest | str join (char space))]
    $p => [$p ...$rest]
  } | if $stdin and ($shell | path basename) == nu { prepend '--stdin' } else { }
    | do --capture-errors {|...args: string| $input | sudo $shell ...$args } ...$in
}

# Run an external command and return its stdout.
#
# On an auth failure (output matching `--pattern`) in an interactive session, run `--login` once and
# retry; any other non-zero exit raises the captured output.
export def --wrapped with-auth [
  name: string
  # The name of the external command to run
  --login (-l): closure
  # Interactive login, e.g. `{|| ^td auth login }` or `{|| ^gh auth login }`
  --pattern: string = $UNAUTHORIZED
  # Regex identifying an auth failure in the command's stdout or stderr
  --strict (-s) = false
  # When `true`, always check the `exit_code` even when no arguments are provided
  ...rest: string
  # The arguments to psas to the external command
]: nothing -> string {
  let check: bool = $strict or ($rest | is-not-empty)
  alias execute = attempt --check=$check --merge=(not $check) $name ...$rest
  try { execute } catch {|err|
    ignore
    if $nu.is-interactive and $login != null and $err.details.help =~ $pattern {
      do $login; execute
    } else {
      error make --unspanned $err.details
    }
  } | if not $check { get $.stdout } else { }
}
