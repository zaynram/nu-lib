# `into completions` formatting and option merging: `test completion/tests/suites`.
use ../mod.nu *

def "test formats elements by type" []: nothing -> nothing {
  let actual = [abc 1 1.5 3KiB 2min 2026-09-14T00:00:00+00:00 true] | completion into completions | get completions
  let expected = [abc "1" "1.5" "3 KiB" "2 min" "2026-09-14T00:00:00+00:00" "true"]
  assert equal $actual $expected 'input order is preserved'
}

def "test quotes only strings that misparse as bare arguments and compacts empties" []: nothing -> nothing {
  let quoted = ["b c" "a'b" 'a"b' "a(b" "a[b" "a{b" "a|b" "a;b" "$a" "-x" "--" "-1" "true" "null"]
  assert equal ($quoted | completion into completions | get completions | where $it !~ '^"') [] 'every misparsing word is quoted'
  let bare = [abc "1" "1.5" "3KiB" "2026-09-13_x" foo-bar x.nu "a#b" "a=b" "a:b" "a,b" "~/x" "*" "." "-" pre_execution.0 true1]
  assert equal ($bare | completion into completions | get completions) $bare 'bare words stay bare'
  assert equal (["" "b c" null a] | completion into completions | get completions) ['"b c"' a]
  assert equal ([[value description]; ["b c" z]] | completion into completions | get completions) [[value description]; ['"b c"' z]]
}

def "test a string list quotes the same with and without escapes" []: nothing -> nothing {
  # every element is a string, so the vectorised pass runs; one escape-needing element sends the list to the formatter
  let plain = [abc "b c" "[" "-x" "true" "it's" "ünï cödé" " lead" "a\\b"]
  assert equal ($plain | completion into completions | get completions) ($plain | each {|s| if $s =~ '[\s"\x27`()\[{}|;$]|^-.|^(true|false|null)$' { $s | to nuon } else { $s } }) 'quoted as `to nuon` quotes'
  for hard in ['a"b' "a\tb" "a\nb\nc" "-\n"] {
    let l = $plain | append $hard
    assert equal ($l | completion into completions | get completions) ($l | each {|s| if $s =~ '[\s"\x27`()\[{}|;$]|^-.|^(true|false|null)$' { $s | to nuon } else { $s } }) $"escaped as `to nuon` escapes: ($hard | to nuon)"
  }
}

def "test options merge over defaults and null restores the default" []: nothing -> nothing {
  let got = [1] | completion into completions {match_description: true sort: null} | get options
  assert equal $got {case_sensitive: false completion_algorithm: prefix match_description: true}
}

def "test a long list keeps its order" []: nothing -> nothing {
  let big = 1..500 | each { $"w($in)" }
  assert equal ($big | completion into completions {sort: false} | get completions) $big
}

def "test generic types reach the text fallback" []: nothing -> nothing {
  let actual = [[1 2] {a: 1}] | completion into completions | get completions
  let expected = [([1 2] | to text) ({a: 1} | to text)]
  assert equal $actual $expected 'describe output is not normalised before matching'
}

def "test repr and to-string overrides" []: nothing -> nothing {
  assert equal ([255 90sec] | completion into completions --repr {number: $.lowerhex duration: sec} | get completions) ["0xff" "90 sec"]
  assert equal ([1 2] | completion into completions --to-string {|| $"<($in)>" } | get completions) ["<1>" "<2>"]
}
