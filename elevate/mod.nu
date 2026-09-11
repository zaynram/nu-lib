# Utilities to ease working with elevated privilges in Nushell.

# Elevate the current shell process.
export def --env --wrapped main [
  ...rest: string # Arguments to pass to the `nu` invocation
]: nothing -> nothing {
  let args: list = $rest
    | if $nu.is-login and $in not-has '--login' and $in not-has '-l' { append [--login] } else { }
  sudo exec $nu.current-exe ...$args
}

# Run a shell command in an elevated context.
export def --env --wrapped sh [
  ...rest: string # Arguments to pass with the invocation
  --script (-s): path # Run this script in an elevated context with the spread arguments passed through
  --shell (-S): path = $nu.current-exe # Path to a shell executable to use for the invocation
]: oneof<nothing, string> -> oneof<nothing, any> {
  let stdin: oneof<nothing, string> = $in
  alias invoke = do --capture-errors {|...args: string| $stdin | sudo $shell ...$args }
  $rest | if $script == null {
    str join (char space) | prepend [--commands]
  } else if ($script | path exists) {
    prepend $script
  } else {
    error make --unspanned 'unable to resolve script path'
  } | if ($shell | path basename) == nu and $rest not-has '--stdin' and $stdin != null {
    prepend [--stdin]
  } else {
  } | invoke ...$in
}
