# Helpers for raising errors.

# Return values are closures intentionally:
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.

# ——— definitions —————————————————————————————————————————————————————————————

# Simple error handler.
# ---
# Throws the error with the message and code unspanned when `--labels` is empty.
# Returns a closure that can be invoked to create the error when `--labels` is not empty.
@category core
export def wrap [
  message: string # Error message to include in the rendered output
  --code: string # An optional identifier to contextualize the error
  --labels: table<text: string, span: record> = [] # Labels to include in the error output
  --help: string # Suggestions or advice on how to avoid or remedy the error
]: oneof<nothing, error, record> -> oneof<error, closure> {
  let details: record = {msg: $message code: $code labels: $labels inner: [$in] help: $help} | compact --empty
  if $labels == [] { error make --unspanned $details } else { return {|| error make $details } }
}

# Errors if the input record contains a non-zero exit code.
export def post-complete [
  name?: string
  # The name of the external command that was called
  --then (-t): closure
  # Closure to invoke with `stdout` as the sole positional argument when the `exit_code` == 0
]: record<stdout: string, stderr: string, exit_code: int> -> oneof<nothing, any, error> {
  if $in.exit_code == 0 {
    get $.stdout | match ($then | describe) { closure => { do $then $in } _ => { } }
  } else {
    error make --unspanned {
      msg: $"(if $name == null { 'external command' } else { $"'($name)'" }) exited with code ($in.exit_code)"
      help: ($in | format pattern "output:\n{stdout}{stderr}")
    }
  }
}
