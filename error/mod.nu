# Helpers for raising errors.

# With `--labels`, `error raise` returns a closure instead of raising, intentionally:
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.

# ——— definitions —————————————————————————————————————————————————————————————

# Simple error handler.
# ---
# Throws the error with the message and code unspanned when `--labels` is empty.
# Returns a closure that can be invoked to create the error when `--labels` is not empty.
# Pipeline input (an error record, e.g. a caught error) becomes the error's single `inner` error; empty `--code` and
# `--advice` values are left out.
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
