# `ansi extern`: `test _tests/suites/style.nu`.
#
# Tests set `$env.config.color_config` explicitly; each runs in its own child, so the changes stay local.
use style
use ../mod.nu *

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

def --env colors [external: any resolved: any arg: any]: nothing -> nothing {
  $env.config.color_config.shape_external = $external
  $env.config.color_config.shape_external_resolved = $resolved
  $env.config.color_config.shape_externalarg = $arg
}

def "test example" []: nothing -> nothing {
  assert equal (style ansi extern git commit -m 'a message' | ansi strip) 'git commit -m "a message"' 'flags and a quoted argument'
}

def "test name only" []: nothing -> nothing {
  colors red yellow green
  assert equal (style ansi extern git) $'(ansi red)git(ansi reset)' 'the name in the external color'
}

def "test name with arguments" []: nothing -> nothing {
  colors red yellow green
  assert equal (style ansi extern git status --short) $'(ansi red)git(ansi reset)(ansi green) status --short(ansi reset)' 'arguments in the argument color'
}

def "test resolved uses the resolved color" []: nothing -> nothing {
  colors red yellow green
  assert equal (style ansi extern --resolved git) $'(ansi yellow)git(ansi reset)' 'shape_external_resolved'
}

def "test record colors" []: nothing -> nothing {
  colors {fg: red attr: b} yellow {fg: blue}
  assert equal (style ansi extern git x) $'(ansi {fg: red attr: b})git(ansi reset)(ansi {fg: blue}) x(ansi reset)' 'style records like the color config uses'
}

def "test attr styles only the name" []: nothing -> nothing {
  colors red yellow green
  assert equal (style ansi extern --attr bold git x) $'(ansi red)(ansi attr_bold)git(ansi reset)(ansi green) x(ansi reset)' 'the attribute follows the color'
  assert equal (style ansi extern --attr italic --resolved git) $'(ansi yellow)(ansi attr_italic)git(ansi reset)' 'with --resolved'
}

def "test an unknown attr is an error listing the valid ones" []: nothing -> nothing {
  let e = caught { style ansi extern --attr nonsense git }
  assert equal $e.msg "unknown attribute 'nonsense'" 'the attribute is named'
  assert equal $e.code 'style::ansi-extern::invalid_argument' 'the derived code names the command with a dash'
  assert str contains ($e.labels.0?.text? | default '') 'bold, dimmed, italic' 'the valid attributes are listed'
}

def "test flag like arguments are passed through" []: nothing -> nothing {
  assert equal (style ansi extern git commit -m msg --amend | ansi strip) 'git commit -m msg --amend' 'unknown flags are arguments'
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
  colors null null null
  assert equal (style ansi extern git) $'(ansi cyan)git(ansi reset)' 'a null key counts as unset'
}
