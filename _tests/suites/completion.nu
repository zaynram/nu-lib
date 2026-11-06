# `completion` record builders and the `completion/local` external completers: `test _tests/suites/completion.nu`.
#
# `fish` and `carapace` are replaced by stub scripts on PATH wherever the logic around them is under test; the
# end-to-end cases run the real programs and skip when they are not installed.
use completion
use completion/local
use ../mod.nu *

# The default formatter's quoting rule, restated: quote what would misparse as a bare argument.
const UNSAFE: string = '[\s"\x27`()\[{}|;$]|^-.|^#|^(true|false|null)$'

# ——— helpers ——————————————————————————————————————————————————————————————————

# What `to nuon` makes of each string that misparses bare; the rest unchanged.
def nuon-quoted []: list<string> -> list<string> {
  each {|s| if $s =~ $UNSAFE { $s | to nuon } else { $s } }
}

# Write an executable `sh` script named `name` into `dir`.
def stub [dir: path name: path body: string]: nothing -> nothing {
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
}

# Run `action` with stub `fish` and `carapace` scripts first on PATH:
# - fish prints its `--command` argument as a value, then the lines in `$FISH_STUB_OUT`
# - carapace prints `$CARAPACE_STUB_OUT` when set, else a JSON row whose value is its arguments
def with-stubs [action: closure]: nothing -> nothing {
  with-sandbox {|ctx|
    stub $ctx.code fish 'printf "%s\tcommand\n" "$2"; [ -n "$FISH_STUB_OUT" ] && printf "%s\n" "$FISH_STUB_OUT"; exit 0'
    stub $ctx.code carapace 'if [ -n "$CARAPACE_STUB_OUT" ]; then printf "%s" "$CARAPACE_STUB_OUT"; else printf "[{\"value\": \"%s\"}]" "$*"; fi'
    with-env {PATH: ($env.PATH | prepend $ctx.code)} { do $action $ctx | ignore }
  }
}

# A command with a category that `help commands` reports as `custom_core` (see `runtime-env`).
@category core
def "zz annotated" []: nothing -> nothing { }

# ——— completion: into completions ———————————————————————————————————————————————

def "test formats elements by type" []: nothing -> nothing {
  let actual = [abc 1 1.5 3KiB 2min 2026-09-14T00:00:00+00:00 true] | completion into completions | get completions
  let expected = [abc "1" "1.5" "3 KiB" "2 min" "2026-09-14T00:00:00+00:00" "true"]
  assert equal $actual $expected 'input order is preserved'
}

def "test quotes only strings that misparse as bare arguments and compacts empties" []: nothing -> nothing {
  let quoted = ["b c" "a'b" 'a"b' "a(b" "a[b" "a{b" "a|b" "a;b" "$a" "-x" "--" "-1" "true" "null" "#a" "#"]
  assert equal ($quoted | completion into completions | get completions | where $it !~ '^"') [] 'every misparsing word is quoted'
  let bare = [abc "1" "1.5" "3KiB" "2026-09-13_x" foo-bar x.nu "a#b" "a=b" "a:b" "a,b" "~/x" "*" "." "-" pre_execution.0 true1]
  assert equal ($bare | completion into completions | get completions) $bare 'bare words stay bare'
  assert equal (["" "b c" null a] | completion into completions | get completions) ['"b c"' a] 'empty and null elements are dropped'
  assert equal ([[value description]; ["b c" z]] | completion into completions | get completions) [[value description]; ['"b c"' z]] 'table values are quoted too'
}

def "test a leading hash is quoted on every path" []: nothing -> nothing {
  # a bare `#a` after a space starts a comment and swallows the completion
  assert equal (["#a" "a#b"] | completion into completions | get completions) ['"#a"' 'a#b'] 'vectorised string pass'
  assert equal (["#a" 1] | completion into completions | get completions) ['"#a"' '1'] 'per-element formatter'
  assert equal (["#a" 'a"b'] | completion into completions | get completions) ['"#a"' '"a\"b"'] 'formatter fallback for escapes'
  assert equal ([[value]; ["#a"]] | completion into completions | get completions) [[value]; ['"#a"']] 'table values'
}

def "test a string list quotes the same with and without escapes" []: nothing -> nothing {
  # every element is a string, so the vectorised pass runs; one escape-needing element sends the list to the formatter
  let plain = [abc "b c" "[" "-x" "true" "it's" "ünï cödé" " lead" "a\\b" "#x"]
  assert equal ($plain | completion into completions | get completions) ($plain | nuon-quoted) 'quoted as `to nuon` quotes'
  for hard in ['a"b' "a\tb" "a\nb\nc" "-\n"] {
    let l = $plain | append $hard
    assert equal ($l | completion into completions | get completions) ($l | nuon-quoted) $"escaped as `to nuon` escapes: ($hard | to nuon)"
  }
}

def "test options merge over defaults and null restores the default" []: nothing -> nothing {
  let got = [1] | completion into completions {match_description: true sort: null} | get options
  assert equal $got {case_sensitive: false completion_algorithm: prefix match_description: true} 'merged, null removed'
  let defaults = [1] | completion into completions | get options
  assert equal $defaults {sort: true case_sensitive: false completion_algorithm: prefix match_description: false} 'defaults'
}

def "test a long list keeps its order" []: nothing -> nothing {
  let big = 1..500 | each { $"w($in)" }
  assert equal ($big | completion into completions {sort: false} | get completions) $big 'order survives the per-element formatter'
}

def "test generic types reach the text fallback" []: nothing -> nothing {
  let actual = [[1 2] {a: 1}] | completion into completions | get completions
  let expected = [([1 2] | to text) ({a: 1} | to text)]
  assert equal $actual $expected 'describe output is not normalised before matching'
}

def "test repr and to-string overrides" []: nothing -> nothing {
  assert equal ([255 90sec] | completion into completions --repr {number: $.lowerhex duration: sec} | get completions) ["0xff" "90 sec"] 'number and duration'
  assert equal ([2026-01-02T03:04:05+00:00] | completion into completions --repr {datetime: '%F'} | get completions) ["2026-01-02"] 'the datetime key'
  assert equal ([2KiB] | completion into completions --repr {filesize: B} | get completions) ["2048 B"] 'filesize'
  assert equal ([1 2] | completion into completions --to-string {|| $"<($in)>" } | get completions) ["<1>" "<2>"] 'a custom formatter'
}

def "test a table formats only its value column" []: nothing -> nothing {
  let got = [[value description extra]; [1.0 one 2] ["b c" two 3]] | completion into completions | get completions
  assert equal $got [[value description extra]; ["1" one 2] ['"b c"' two 3]] 'description and extra columns pass through'
  let custom = [[value description]; [1 one]] | completion into completions --to-string {|| $"<($in)>" } | get completions
  assert equal $custom [[value description]; ["<1>" one]] 'to-string applies to the value column'
}

def "test a table without a value column is an error" []: nothing -> nothing {
  assert error { [[a b]; [1 2]] | completion into completions } 'a table is always a completion table'
}

def "test empty input gives no completions" []: nothing -> nothing {
  assert equal ([] | completion into completions | get completions) [] 'empty list'
  assert equal ([null ""] | completion into completions | get completions) [] 'only empties'
}

def "test the examples hold" []: nothing -> nothing {
  let examples = scope commands | where name == 'completion into completions' | first | get examples
  assert equal ([1 2 3] | completion into completions) ($examples | get 0.result) 'list example'
  let table = [[description value]; ['/tmp/a b.nu' 'a b.nu']] | completion into completions {match_description: true}
  assert equal $table ($examples | get 1.result) 'table example'
}

# ——— completion: into spans / structure ———————————————————————————————————————

def "test into spans returns token texts" []: nothing -> nothing {
  assert equal ('ls | where' | completion into spans) [ls "|" where] 'pipes are tokens'
  assert equal ("git commit -m 'a b'" | completion into spans) [git commit -m "'a b'"] 'quoted words stay whole'
  assert equal ('' | completion into spans) [] 'an empty buffer has no tokens'
}

def "test trailing whitespace appends an empty token unless raw" []: nothing -> nothing {
  assert equal ('git ' | completion into spans) [git ""] 'the word being started'
  assert equal ('git ' | completion into spans --raw) [git] '--raw'
  assert equal ('  ' | completion into spans) [""] 'whitespace only'
}

def "test long returns the structure table" []: nothing -> nothing {
  let rows = 'ls  ' | completion into spans --long
  assert equal ($rows | columns) [text kind span] 'structure columns'
  assert equal ($rows | first | get span) {start: 0 end: 2} 'byte span of the first token'
  assert equal ($rows | last) {text: '' kind: none span: {start: 3 end: 3}} 'the appended empty token'
}

def "test unalias replaces the first token with the alias expansion" []: nothing -> nothing {
  alias zzg = ^git --no-pager
  assert equal ('zzg st' | completion into spans --unalias) [git st] 'first word of the expansion'
  assert equal ('zzg st' | completion into spans) [zzg st] 'only with --unalias'
  assert equal ('zzq st' | completion into spans --unalias) [zzq st] 'not an alias'
  assert equal ('' | completion into spans --unalias) [] 'an empty buffer'
}

def "test structure is re-exported" []: nothing -> nothing {
  assert equal (completion structure 'ls -a' | get text) [ls -a] 'std/util structure'
}

# ——— completion/local: surface ————————————————————————————————————————————————————

def "test local re-exports completion" []: nothing -> nothing {
  let names = scope commands | where name starts-with 'local ' | get name | sort
  let expected = [
    'local carapace-complete' 'local carapace-complete runtime-env' 'local fish-complete'
    'local fish-complete parse-output' 'local into completions' 'local into spans' 'local run-completer'
    'local set-completer' 'local structure'
  ]
  assert equal $names $expected 'the exported surface'
  assert equal ([a "b c"] | local into completions) ([a "b c"] | completion into completions) 'same builders'
}

# ——— completion/local: fish ———————————————————————————————————————————————————————

def "test parse-output reads values and descriptions" []: nothing -> nothing {
  let got = "status\tShow the working tree status\nplain" | local fish-complete parse-output
  assert equal $got [{value: status description: 'Show the working tree status'} {value: plain}] 'one row per line'
  assert equal ('' | local fish-complete parse-output) [] 'no output'
}

def "test parse-output quotes existing paths with special characters" []: nothing -> nothing {
  with-sandbox {|ctx|
    let d = $ctx.code
    for name in ['a b' 'c\d' 'q"q' plain] { mkdir ($d | path join $name) }
    let lines = [$"($d)/a b" $"($d)/c\\d" $"($d)/q\"q" $"($d)/plain" 'no such/a b'] | each { $"($in)\tD" } | str join "\n"
    let got = $lines | local fish-complete parse-output | get value
    assert equal $got [$'"($d)/a b"' $'"($d)/c\\d"' $'"($d)/q\"q"' $"($d)/plain" 'no such/a b'] 'quoted with \ and " escaped'
  }
}

def "test parse-output always expands a leading tilde" []: nothing -> nothing {
  let got = "~/zz-missing\tD\n~\tH\na~b\tX" | local fish-complete parse-output | get value
  assert equal $got [($nu.home-dir | path join zz-missing) $nu.home-dir 'a~b'] 'leading ~ only, existing or not'
}

def "test fish-complete escapes the buffer for a fish single-quoted string" []: nothing -> nothing {
  with-stubs {|ctx|
    let got = [echo] | local fish-complete "echo it's a\\" | get value
    assert equal $got ["complete '--do-complete=echo it\\'s a\\\\'"] 'backslash and quote escaped'
  }
}

def "test fish-complete keeps only values extending the final span" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {FISH_STUB_OUT: "status\tS\nstash\tT\nst\tX\nother\tO\n~/stx\tH"} {
      assert equal ([git st] | local fish-complete 'git st' | get value) [status stash] 'prefix kept, exact match dropped'
      assert equal ([git] | local fish-complete 'git' | length) 6 'no final span: no filter'
      assert equal ([git '~/st'] | local fish-complete 'git ~/st' | get value) [($nu.home-dir | path join stx)] 'filtered before ~ is expanded'
    }
  }
}

def "test fish-complete runs fish" []: nothing -> nothing {
  if (which fish | is-empty) { skip 'fish is not installed' }
  let got = [git stat] | local fish-complete 'git stat'
  assert ('status' in $got.value) 'git subcommands complete'
  assert ($got.value | all { str starts-with stat }) 'only values extending the final span'
}

# ——— completion/local: carapace ———————————————————————————————————————————————————

def "test runtime-env lists command names as newline-separated strings" []: nothing -> nothing {
  let found = local carapace-complete runtime-env
  assert equal ($found | columns | sort) [CARAPACE_SHELL_BUILTINS CARAPACE_SHELL_FUNCTIONS] 'both variables'
  assert equal ($found | values | each { describe } | uniq) [string] 'strings, which externals receive'
  let builtins = $found.CARAPACE_SHELL_BUILTINS | lines
  let functions = $found.CARAPACE_SHELL_FUNCTIONS | lines
  assert ('ls' in $builtins) 'a builtin'
  assert ('str' in $builtins and 'str join' not-in $builtins) 'first words only'
  assert ('zz' in $functions and 'zz' not-in $builtins) 'a custom command with a category is a function'
  assert ('local' in $functions) 'an imported custom command is a function'
}

def "test carapace-complete passes spans and the runtime env to carapace" []: nothing -> nothing {
  with-stubs {|ctx|
    stub $ctx.code carapace 'printf "%s" "$CARAPACE_SHELL_BUILTINS" | grep -qx ls && b=yes || b=no; printf "[{\"value\": \"%s\", \"description\": \"%s\"}]" "$*" "$b"'
    assert equal ([git stat] | local carapace-complete git) [{value: 'git nushell git stat' description: yes}] 'name, shell, spans; builtins visible'
  }
}

def "test carapace-complete deserializes by shell" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {CARAPACE_STUB_OUT: "status\tS\nstash\tT"} {
      assert equal ([git st] | local carapace-complete git --shell fish | get value) [status stash] 'fish output'
    }
    with-env {CARAPACE_STUB_OUT: "status S\nstash T"} {
      assert equal ([git st] | local carapace-complete git --shell zsh) [status stash] 'first word per line otherwise'
      let custom = [git st] | local carapace-complete git --shell zsh --deserialize {|| lines | each { str uppercase } }
      assert equal $custom ['STATUS S' 'STASH T'] 'a custom deserializer'
    }
  }
}

def "test carapace-complete yields an empty list on failure" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {CARAPACE_STUB_OUT: '{bad'} {
      assert equal ([git st] | local carapace-complete git) [] 'unparsable output'
    }
    stub $ctx.code carapace 'echo oops >&2; exit 3'
    assert equal ([git st] | local carapace-complete git) [] 'a failing carapace'
  }
}

def "test carapace-complete runs carapace" []: nothing -> nothing {
  if (which carapace | is-empty) { skip 'carapace is not installed' }
  let got = [ls --al] | local carapace-complete ls
  assert ($got | is-not-empty) 'flags complete'
  assert ($got.value | all { str starts-with '--al' }) 'only matching flags'
}

# ——— completion/local: set-completer / run-completer ——————————————————————————————

def "test set-completer installs a completer and defaults the fish commands" []: nothing -> nothing {
  local set-completer
  assert equal ($env.config.completions.external.completer | describe) closure 'a completer closure'
  assert equal $env.fish_commands [nu git td asdf] 'fish commands default when unset'
  $env.fish_commands = []
  local set-completer
  assert equal $env.fish_commands [] 'an empty list is kept: fish disabled'
}

def "test the completer routes to fish or carapace" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {FISH_STUB_OUT: "fish-said\tF"} {
      $env.fish_commands = [git]
      local set-completer
      let complete = $env.config.completions.external.completer
      assert equal (do $complete 'git f' | get value) [fish-said] 'listed commands go to fish'
      assert equal (do $complete 'ls x' | get value) ['ls nushell ls x'] 'others go to carapace'
      $env.fish_commands = []
      assert equal (do $complete 'git f' | get value) ['git nushell git f'] 'read at completion time'
    }
  }
}

def "test the completer completes the command under the cursor" []: nothing -> nothing {
  with-stubs {|ctx|
    $env.fish_commands = []
    local set-completer
    let complete = $env.config.completions.external.completer
    assert equal (do $complete 'ls | zzx a' {command: [zzx a]} | get value) ['zzx nushell zzx a'] 'place.command, not the whole buffer'
    assert equal (do $complete 'ls | zzx a' | get value) ['ls nushell ls | zzx a'] 'a buffer alone is tokenised whole'
    assert equal ('echo 1 | zzx a ' | commandline complete) ['zzx nushell zzx a '] 'as Nushell calls it'
  }
}

def "test the completer resolves aliases before routing" []: nothing -> nothing {
  with-stubs {|ctx|
    alias zzc = ^git --no-pager
    $env.fish_commands = []
    local set-completer
    let complete = $env.config.completions.external.completer
    assert equal (do $complete 'zzc x' | get value) ['git nushell git x'] 'carapace gets the expansion'
    $env.fish_commands = [git]
    let got = do $complete 'zzc  ' {command: [zzc ""]} | get value
    assert equal $got ["complete '--do-complete=git '"] 'fish gets the expanded command line'
  }
}

def "test the fallback runs when the provider returns nothing" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {CARAPACE_STUB_OUT: '[]'} {
      local set-completer --default {|buffer| [$"fallback ($buffer)"] }
      assert equal (do $env.config.completions.external.completer 'ls x') ['fallback ls x'] '--default'
    }
  }
}

def "test a previously configured completer becomes the fallback" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {CARAPACE_STUB_OUT: '[]'} {
      $env.config.completions.external.completer = {|buffer| [previous] }
      local set-completer
      assert equal (do $env.config.completions.external.completer 'ls x') [previous] 'the old completer'
    }
  }
}

def "test calling set-completer again keeps the first fallback" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {CARAPACE_STUB_OUT: '[]'} {
      $env.config.completions.external.completer = {|buffer| [previous] }
      local set-completer
      local set-completer
      assert equal (do $env.config.completions.external.completer 'ls x') [previous] 'not chained into itself (X9)'
    }
  }
}

def "test calling set-completer again does not chain the provider" []: nothing -> nothing {
  with-stubs {|ctx|
    let log: path = $ctx.code | path join carapace.log
    stub $ctx.code carapace $"echo call >> '($log)'; printf '[]'"
    local set-completer
    local set-completer
    assert equal (do $env.config.completions.external.completer 'ls x') [] 'no fallback'
    assert equal (open $log | lines | length) 1 'the provider runs once'
  }
}

def "test set-completer with a default replaces its own fallback" []: nothing -> nothing {
  with-stubs {|ctx|
    with-env {CARAPACE_STUB_OUT: '[]'} {
      $env.config.completions.external.completer = {|buffer| [previous] }
      local set-completer
      local set-completer --default {|buffer| [given] }
      assert equal (do $env.config.completions.external.completer 'ls x') [given] '--default wins'
    }
  }
}

def "test an empty buffer completes to nothing" []: nothing -> nothing {
  local set-completer
  assert equal (do $env.config.completions.external.completer '') [] 'no tokens, no provider'
}

def "test run-completer prefers the positional over pipeline input" []: nothing -> nothing {
  with-stubs {|ctx|
    $env.fish_commands = []
    assert equal ('zzz q' | local run-completer 'ls x' | get value) ['ls nushell ls x'] 'the positional wins'
    assert equal ('ls y' | local run-completer | get value) ['ls nushell ls y'] 'pipeline input without a positional'
    assert equal (['ls a' 'ls b'] | local run-completer | each { get value.0 }) ['ls nushell ls a' 'ls nushell ls b'] 'each piped buffer'
    assert equal (local run-completer 'echo 1 | ls x' | get value) ['ls nushell ls x'] 'the command at the end of the buffer'
  }
}

def "test run-completer uses the configured completer and leaves the session unchanged" []: nothing -> nothing {
  $env.config.completions.external.completer = {|buffer| [$"mine ($buffer)"] }
  assert equal (local run-completer 'x') ['mine x'] 'an existing completer is used'
  with-stubs {|ctx|
    $env.fish_commands = []
    $env.config.completions.external.completer = null
    assert equal (local run-completer 'ls x' | get value) ['ls nushell ls x'] 'installed when unset'
    assert equal $env.config.completions.external.completer null 'installing for one call is scoped to it'
  }
}

# ——— completion/local: environment ————————————————————————————————————————————————

# Run `code` in a sandboxed child after `prelude`; return its nuon output.
def child [prelude: string code: string --vars: record = {}]: nothing -> record {
  with-sandbox {|ctx|
    let bin = $ctx.config | path join carapace bin
    sandboxed $ctx $"($code) | to nuon" --prelude $prelude --vars $vars --pipe | insert bin $bin
  }
}

const ENV_PROBE: string = '{
  lenient: $env.CARAPACE_LENIENT?
  bridges: $env.CARAPACE_BRIDGES?
  path: $env.PATH
  conversions: ($env.ENV_CONVERSIONS | columns)
  commands: (scope commands | where name =~ "complete|completer" | get name | where $it !~ "^(complete|attr|generate|commandline)")
}'

def "test importing local sets up the environment" []: nothing -> nothing {
  let got = child 'use completion/local' $ENV_PROBE
  assert equal $got.lenient '1' 'CARAPACE_LENIENT'
  assert equal $got.bridges 'zsh,fish,bash,complete,argcomplete,clap' 'CARAPACE_BRIDGES'
  assert equal ($got.path | first) $got.bin 'the carapace bin dir leads PATH'
  assert ('fish_commands' in $got.conversions) 'the fish_commands conversion'
}

def "test the environment set-up keeps existing values and is idempotent" []: nothing -> nothing {
  let got = child 'use completion/local; use completion/local *' $ENV_PROBE --vars {CARAPACE_LENIENT: '0'}
  assert equal $got.lenient '0' 'an existing value wins'
  assert equal ($got.path | where $it == $got.bin | length) 1 'PATH gains the bin dir once'
}

def "test the fish_commands conversion round-trips" []: nothing -> nothing {
  let conv = $env.ENV_CONVERSIONS.fish_commands
  assert equal (do $conv.to_string [a b]) $"a(char esep)b" 'joined with the path separator'
  assert equal (do $conv.from_string $"a(char esep)b(char esep)a") [a b] 'split and deduplicated'
}

def "test the deprecated external shim keeps its imports and environment" []: nothing -> nothing {
  let got = child 'use completion/external set-completer' $"set-completer; ($ENV_PROBE) | insert completer \($env.config.completions.external.completer | describe\)"
  assert equal $got.commands [set-completer] "the owner's autoload import"
  assert equal $got.completer closure 'set-completer works'
  assert equal [$got.lenient ($got.path | first)] ['1' $got.bin] 'the environment set-up runs'
  assert ('fish_commands' in $got.conversions) 'the fish_commands conversion'
  let all = child 'use completion/external *' $ENV_PROBE
  let expected = [
    carapace-complete 'carapace-complete runtime-env' fish-complete 'fish-complete parse-output' run-completer set-completer
  ]
  assert equal ($all.commands | sort) $expected 'the old surface, nothing more'
}
