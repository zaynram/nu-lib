# Helpers for raising errors.

# Return values are closures intentionally:
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.

# ——— definitions —————————————————————————————————————————————————————————————

# Simple error handler.
# ---
# Throws the error with the message and code unspanned when `--labels` is empty.
# Returns a closure that can be invoked to create the error when `--labels` is not empty.
@category core
export def raise [
  message: string # Error message to include in the rendered output
  --code: string # An optional identifier to contextualize the error
  --labels: table<text: string, span: record> = [] # Labels to include in the error output
  --advice: string # Suggestions or advice on how to avoid or remedy the error
]: oneof<nothing, error, record> -> oneof<error, closure> {
  let details: record = append []
    | {msg: $message code: $code labels: $labels inner: $in help: $advice}
    | compact --empty
  if $labels == [] { error make --unspanned $details } else { return {|| error make $details } }
}
