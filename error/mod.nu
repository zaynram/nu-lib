# ——— definitions —————————————————————————————————————————————————————————————

# Simple error handler; shows message and code unspanned.
export def wrap [
  ...text: string # Error message to include in the rendered output (joined with `--char`)
  --code: string # An optional identifier to contextualize the error
  --char: string@_char-names = newline # Character to use to join the `text` arguments
]: oneof<nothing, error, record> -> error {
  error make --unspanned ({msg: ($text | str join (char $char)) code: $code} | compact --empty)
}

# ——— completions ———————————————————————————————————————————————————————————

def _char-names []: nothing -> list { char --list }
