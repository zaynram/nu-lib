# `colors`, `paint` and `ansi extern`: `test _tests/suites/style.nu`.
#
# Tests set `$env.config.color_config` and `use_ansi_coloring` explicitly; each runs in its own child, so the changes
# stay local. A test child has no terminal, so with the default `auto` colours are off: `before each` turns them on,
# and the tests about the gate set the value they need.
use style
use ../mod.nu *

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

def --env "before each" []: nothing -> nothing { $env.config.use_ansi_coloring = true }

def --env shapes [external: any resolved: any arg: any]: nothing -> nothing {
  $env.config.color_config.shape_external = $external
  $env.config.color_config.shape_external_resolved = $resolved
  $env.config.color_config.shape_externalarg = $arg
}

# ——— colors ———————————————————————————————————————————————————————————————————

def "test colors follows use_ansi_coloring" []: nothing -> nothing {
  assert equal (style colors) true 'true: on'
  $env.config.use_ansi_coloring = false
  assert equal (style colors) false 'false: off'
}

def "test colors is off for auto without a terminal" []: nothing -> nothing {
  $env.config.use_ansi_coloring = 'auto'
  assert equal (style colors) false 'a test child has no terminal'
}

def "test colors honours the colour variables only for auto" []: nothing -> nothing {
  with-sandbox {|ctx|
    let auto: closure = {|vars| sandboxed $ctx 'style colors | to nuon' --prelude 'use style' --vars $vars --pipe }
    # The child's stdout is a pipe, so `auto` is off already: NO_COLOR is only observable against CLICOLOR, which
    # opens the gate without a terminal.
    assert equal (do $auto {CLICOLOR: '1'}) true 'CLICOLOR=1 turns auto on without a terminal'
    assert equal (do $auto {CLICOLOR: '1' NO_COLOR: '1'}) false 'NO_COLOR turns auto off again'
    assert equal (do $auto {NO_COLOR: '1' FORCE_COLOR: '1'}) true 'FORCE_COLOR beats NO_COLOR'
    let forced: bool = sandboxed $ctx '$env.config.use_ansi_coloring = true; style colors | to nuon' --prelude 'use style' --vars {NO_COLOR: '1'} --pipe
    assert equal $forced true 'an explicit true wins over NO_COLOR'
  }
}

# ——— paint ————————————————————————————————————————————————————————————————————

def "test paint wraps the text when colours are on" []: nothing -> nothing {
  assert equal ('ok' | style paint green) $'(ansi green)ok(ansi reset)' 'one code and a reset'
  assert equal ('ok' | style paint green attr_bold) $'(ansi green)(ansi attr_bold)ok(ansi reset)' 'codes in order, one reset'
  assert equal ('ok' | style paint wd) $'(ansi wd)ok(ansi reset)' 'short names too'
}

def "test paint returns the text when colours are off" []: nothing -> nothing {
  $env.config.use_ansi_coloring = false
  assert equal ('ok' | style paint green attr_bold) ok 'no escape sequences'
}

def "test paint without codes returns the text" []: nothing -> nothing {
  assert equal ('ok' | style paint) ok 'nothing to apply, no reset either'
}

def "test paint colors flag overrides the setting" []: nothing -> nothing {
  assert equal ('ok' | style paint green --colors=false) ok 'false suppresses'
  $env.config.use_ansi_coloring = false
  assert equal ('ok' | style paint green --colors=true) $'(ansi green)ok(ansi reset)' 'true forces'
}

def "test paint rejects an unknown code in both modes" []: nothing -> nothing {
  let on = caught { 'x' | style paint green nonsense }
  assert equal $on.msg "unknown ansi code 'nonsense'" 'the code is named'
  assert equal $on.code 'style::paint::invalid_argument' 'the derived code'
  assert str contains ($on.labels.0?.text? | default '') 'ansi --list' 'the label points at the list'
  $env.config.use_ansi_coloring = false
  assert equal (caught { 'x' | style paint nonsense }).code 'style::paint::invalid_argument' 'also when colours are off'
}

# ——— ansi extern ——————————————————————————————————————————————————————————————

def "test example" []: nothing -> nothing {
  assert equal (style ansi extern git commit -m 'a message' | ansi strip) 'git commit -m "a message"' 'flags and a quoted argument'
}

def "test name only" []: nothing -> nothing {
  shapes red yellow green
  assert equal (style ansi extern git) $'(ansi red)git(ansi reset)' 'the name in the external color'
}

def "test name with arguments" []: nothing -> nothing {
  shapes red yellow green
  assert equal (style ansi extern git status --short) $'(ansi red)git(ansi reset)(ansi green) status --short(ansi reset)' 'arguments in the argument color'
}

def "test resolved uses the resolved color" []: nothing -> nothing {
  shapes red yellow green
  assert equal (style ansi extern --resolved git) $'(ansi yellow)git(ansi reset)' 'shape_external_resolved'
}

def "test record colors" []: nothing -> nothing {
  shapes {fg: red attr: b} yellow {fg: blue}
  assert equal (style ansi extern git x) $'(ansi {fg: red attr: b})git(ansi reset)(ansi {fg: blue}) x(ansi reset)' 'style records like the color config uses'
}

def "test attr styles only the name" []: nothing -> nothing {
  shapes red yellow green
  assert equal (style ansi extern --attr bold git x) $'(ansi red)(ansi attr_bold)git(ansi reset)(ansi green) x(ansi reset)' 'the attribute follows the color'
  assert equal (style ansi extern --attr italic --resolved git) $'(ansi yellow)(ansi attr_italic)git(ansi reset)' 'with --resolved'
}

def "test an unknown attr is an error listing the valid ones" []: nothing -> nothing {
  let e = caught { style ansi extern --attr nonsense git }
  assert equal $e.msg "unknown attribute 'nonsense'" 'the attribute is named'
  assert equal $e.code 'style::ansi-extern::invalid_argument' 'the derived code names the command with a dash'
  assert str contains ($e.labels.0?.text? | default '') 'bold, dimmed, italic' 'the valid attributes are listed'
  $env.config.use_ansi_coloring = false
  assert equal (caught { style ansi extern --attr nonsense git }).code 'style::ansi-extern::invalid_argument' 'also when colours are off'
}

def "test ansi extern is plain when colours are off" []: nothing -> nothing {
  $env.config.use_ansi_coloring = false
  shapes red yellow green
  assert equal (style ansi extern git status --short) 'git status --short' 'name and arguments, no escape sequences'
  assert equal (style ansi extern --attr bold --resolved git 'a b' '') 'git "a b" ""' 'quoting still applies'
}

def "test flag like arguments are passed through" []: nothing -> nothing {
  assert equal (style ansi extern git commit -m msg --amend | ansi strip) 'git commit -m msg --amend' 'unknown flags are arguments'
}

def "test known flags are parsed wherever they appear" []: nothing -> nothing {
  shapes red yellow green
  assert equal (style ansi extern git --resolved) $'(ansi yellow)git(ansi reset)' '--resolved after the name is the flag, not an argument'
  assert equal (style ansi extern git --attr bold x) $'(ansi red)(ansi attr_bold)git(ansi reset)(ansi green) x(ansi reset)' '--attr after the name too'
}

def "test arguments with whitespace are quoted" []: nothing -> nothing {
  assert equal (style ansi extern echo 'c d' e | ansi strip) 'echo "c d" e' 'one argument with a space'
  # (`ansi strip` would also drop the tab)
  assert str contains (style ansi extern echo "tab\there") " \"tab\there\"" 'other whitespace too'
  assert equal (style ansi extern echo '' | ansi strip) 'echo ""' 'an empty argument'
  assert equal (style ansi extern echo 'say "hi" now' | ansi strip) 'echo "say \"hi\" now"' 'inner quotes are escaped'
}

def "test missing colors fall back to the defaults" []: nothing -> nothing {
  $env.config.color_config = ($env.config.color_config | reject shape_external shape_external_resolved shape_externalarg)
  assert equal (style ansi extern git a) $'(ansi cyan)git(ansi reset)(ansi green_bold) a(ansi reset)' 'cyan name, bold green arguments'
  assert equal (style ansi extern --resolved git) $'(ansi light_yellow_bold)git(ansi reset)' 'light yellow bold when resolved'
}

def "test null colors fall back to the defaults" []: nothing -> nothing {
  shapes null null null
  assert equal (style ansi extern git) $'(ansi cyan)git(ansi reset)' 'a null key counts as unset'
}
