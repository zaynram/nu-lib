# Extensions to the built-in `ansi` command providing additional style methods.

# ——— definitions ——————————————————————————————————————————————————————————————

# Style a command (optionally with arguments) using the color config.
export def "ansi extern" [
  name: string
  # The name of the command to style
  --resolved
  # Use the `shape_external_resolved` instead of `shape_external`
  --attr: string@_ansi_attributes
  # Additional attributes to apply (command name only)
  ...rest: string
  # Arguments to style using the `shape_externalarg` color
]: nothing -> string {
  let pre: string = if $attr != null { try { ansi attr_($attr) } } | to text
  let end: string = if $rest != [] {
    let base: string = ansi $env.config.color_config.shape_externalarg
    $rest | reduce --fold=$base {|a| $"($in) ($a)" } | $"($in)(ansi reset)"
  } | to text
  $env.config.color_config
  | if $resolved { ansi $in.shape_external_resolved } else { ansi $in.shape_external }
  | $"($in)($pre)($name)(ansi reset)($end)"
}

# ——— completions ——————————————————————————————————————————————————————————————

def _ansi_attributes []: nothing -> list {
  'ansi attr_' | commandline complete | str replace attr_ ''
}
