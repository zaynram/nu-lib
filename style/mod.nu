# Extensions to the built-in `ansi` command providing additional style methods, and the one place that decides
# whether the library emits ANSI at all.
#
# Every colour the library prints goes through `paint` (or is gated on `colors`), so `$env.config.use_ansi_coloring`
# (`true`, `false` or `auto`), the `FORCE_COLOR`/`NO_COLOR`/`CLICOLOR` variables and the terminal are honoured
# everywhere, through `config use-colors`. The builtin `ansi` itself ignores that setting.

# ——— imports ——————————————————————————————————————————————————————————————————

use error

# ——— constants ————————————————————————————————————————————————————————————————

# Nushell's own colors for the external-command shapes, used when the color config does not set them.
const SHAPE_DEFAULTS: record = {
  shape_external: cyan
  shape_external_resolved: light_yellow_bold
  shape_externalarg: green_bold
}
const SHAPES: list<string> = [shape_external shape_external_resolved shape_externalarg]

# ——— definitions ——————————————————————————————————————————————————————————————

# Whether output should carry ANSI styles: `config use-colors`.
#
# That builtin is the only correct check: it resolves `$env.config.use_ansi_coloring` (`true`, `false`, or `auto`).
# For `auto` the environment is consulted in this order, a variable counting as set when it is non-empty and not
# `0`/`false`: `FORCE_COLOR` set turns colours on, terminal or not and over `NO_COLOR`; otherwise `NO_COLOR` set turns
# them off; otherwise a present `CLICOLOR` decides (set: on, terminal or not; `0`, `false` or empty: off); otherwise
# colours are on when stdout is a terminal and `TERM` is not `dumb`. `CLICOLOR_FORCE` has no effect. Do not read
# `$env.config.use_ansi_coloring` directly.
@category formats
export def colors []: nothing -> bool { config use-colors }

# Wrap the input in ANSI codes and a reset when colours are on; return it unchanged otherwise.
#
# Codes are names from `ansi --list` (`green`, `dark_gray_bold`, `attr_dimmed`, `wd`, …), applied in order. An unknown
# name is an error whether colours are on or off, so a typo surfaces without a terminal too. `--colors` overrides the
# check, for commands that expose their own `--colors` flag (`validate rules`): `true` styles without a terminal,
# `false` never does.
@category formats
@example 'a dimmed note' { 'in 2s' | paint attr_dimmed --colors=true } --result $"(ansi attr_dimmed)in 2s(ansi reset)"
@example 'nothing when colours are off' { 'ok' | paint green --colors=false } --result ok
export def paint [
  ...codes: string@_ansi_codes
  # Names from `ansi --list`, applied in order
  --colors (-c): oneof<nothing, bool>
  # Style regardless of the terminal (`true`) or never (`false`); default: `colors`
]: string -> string {
  let text: string = $in
  let prefix: string = $codes | each {|code|
    try { ansi $code } catch {
      error raise $"unknown ansi code '($code)'" ...{
        kind: invalid_argument
        labels: [
          {text: 'not a name from `ansi --list`' span: (metadata $codes).span}
        ]
      } | do $in
    }
  } | str join
  if $codes != [] and ($colors | default { colors }) { $"($prefix)($text)(ansi reset)" } else { $text }
}

# Style a command (optionally with arguments) using the color config; plain text when colours are off (`colors`).
#
# The name takes `shape_external` (or `shape_external_resolved`) and the arguments `shape_externalarg` from
# `$env.config.color_config`, falling back to Nushell's default colors for keys it does not set. `--resolved` and
# `--attr` are recognised wherever they appear, before or after the name; every other flag-like word is an argument,
# taken as written (`--wrapped`). Arguments that contain whitespace, or are empty, are shown quoted.
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
  # The attribute is checked before the colour decision, so a bad name is an error without a terminal too.
  let pre: string = if $attr == null { '' } else if $attr in (_ansi_attributes) { ansi $'attr_($attr)' } else {
    error raise $"unknown attribute '($attr)'" ...{
      kind: invalid_argument
      labels: [
        {text: $"expected one of: (_ansi_attributes | str join ', ')" span: (metadata $attr).span}
      ]
    } | do $in
  }
  let args: string = if $rest == [] { '' } else {
    ' ' + ($rest | each { if $in =~ '\s' or $in == '' { to nuon } else { } } | str join ' ')
  }
  if not (colors) { return $"($name)($args)" }
  # `record where`, not `select`: `path` exports a `select`, and a module parsed before this one leaks its names into
  # this parse (as the runner's `skip` does), so `use path` followed by `use style` would otherwise fail to parse.
  let shapes: record = $SHAPE_DEFAULTS | merge ($env.config?.color_config? | default {} | record where key in $SHAPES and value != null)
  let end: string = if $args == '' { '' } else { $"(ansi $shapes.shape_externalarg)($args)(ansi reset)" }
  let color: any = if $resolved { $shapes.shape_external_resolved } else { $shapes.shape_external }
  $"(ansi $color)($pre)($name)(ansi reset)($end)"
}

# ——— completions ——————————————————————————————————————————————————————————————

def _ansi_codes []: nothing -> list<string> { ansi --list | get name }

def _ansi_attributes []: nothing -> list<string> {
  ansi --list | get name | where $it starts-with attr_ | str replace attr_ ''
}
