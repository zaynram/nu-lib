# Extensions to the built-in `ansi` command providing additional style methods.

# ——— constants ————————————————————————————————————————————————————————————————

# Nushell's own colors for the external-command shapes, used when the color config does not set them.
const SHAPE_DEFAULTS: record = {
  shape_external: cyan
  shape_external_resolved: light_yellow_bold
  shape_externalarg: green_bold
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Style a command (optionally with arguments) using the color config.
#
# The name takes `shape_external` (or `shape_external_resolved`) and the arguments `shape_externalarg` from
# `$env.config.color_config`, falling back to Nushell's default colors for keys it does not set. Arguments are
# taken as written, flags included (put `--resolved`/`--attr` before the name); arguments that contain whitespace,
# or are empty, are shown quoted.
@category formats
@example 'a command with arguments' { ansi extern git commit -m 'a message' | ansi strip } --result "git commit -m \"a message\""
export def --wrapped "ansi extern" [
  name: string
  # The name of the command to style
  --resolved
  # Use the `shape_external_resolved` instead of `shape_external`
  --attr: string@_ansi_attributes
  # Additional attribute to apply to the command name: a name from `ansi --list` without `attr_` (e.g. `bold`)
  ...rest: string
  # Arguments to style using the `shape_externalarg` color
]: nothing -> string {
  let colors: record = $SHAPE_DEFAULTS | merge ($env.config?.color_config? | default {} | select --optional ...($SHAPE_DEFAULTS | columns) | compact)
  let pre: string = if $attr == null { '' } else if $attr in (_ansi_attributes) { ansi $'attr_($attr)' } else {
    error make {
      msg: $"unknown attribute '($attr)'"
      label: {text: $"expected one of: (_ansi_attributes | str join ', ')" span: (metadata $attr).span}
    }
  }
  let end: string = if $rest == [] { '' } else {
    let args: string = $rest | each { if $in =~ '\s' or $in == '' { to nuon } else { } } | str join ' '
    $"(ansi $colors.shape_externalarg) ($args)(ansi reset)"
  }
  let color: any = if $resolved { $colors.shape_external_resolved } else { $colors.shape_external }
  $"(ansi $color)($pre)($name)(ansi reset)($end)"
}

# ——— completions ——————————————————————————————————————————————————————————————

def _ansi_attributes []: nothing -> list<string> {
  ansi --list | get name | where $it starts-with attr_ | str replace attr_ ''
}
