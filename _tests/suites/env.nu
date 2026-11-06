# `env` getters, setters, existence tests and `.env` parsing: `test _tests/suites/env.nu`.
#
# Every test runs in its own scrubbed child interpreter, so variables set here never leak into other tests.
use env
use ../mod.nu *

# Write `.env` text into a fresh sandbox and run `action` with its path.
def with-dotenv [text: string action: closure]: nothing -> oneof<record, table> {
  with-sandbox {|ctx|
    let file: path = $ctx.code | path join .env
    $text | save $file
    do $action $file
  }
}

const DOTENV = r#'A=1
# COMMENTED=out

  SPACED = "x y"
EQ=1=2
SINGLE='q'
UNBALANCED="open
'#

# ——— env (main) ———————————————————————————————————————————————————————————————

def "test a single name returns the bare value" []: nothing -> nothing {
  $env.SBENV_ONE = 'one'
  assert equal (env SBENV_ONE) 'one' 'one name returns its value, not a one-element list'
}

def "test a missing name returns null" []: nothing -> nothing {
  assert equal (env SBENV_MISSING) null 'missing variables are null by default'
}

def "test a missing name raises without optional" []: nothing -> nothing {
  assert error {|| env --optional=false SBENV_MISSING } 'optional=false raises on a missing variable'
}

def "test names match case insensitively by default" []: nothing -> nothing {
  $env.SBENV_CASE = 'v'
  assert equal (env sbenv_case) 'v' 'lookup ignores case by default'
  assert equal (env --ignore-case=false sbenv_case) null 'ignore-case=false requires the exact spelling'
}

def "test several names return a list of values" []: nothing -> nothing {
  $env.SBENV_A = 'a'
  $env.SBENV_B = 'b'
  assert equal (env SBENV_A SBENV_B) [a b] 'several names return their values in order'
}

def "test no names returns the environment without prompt variables" []: nothing -> nothing {
  $env.SBENV_ALL = 'x'
  let all: record = env
  assert equal $all.SBENV_ALL 'x' 'ordinary variables are kept'
  assert ($all | columns | where $it in [config PROMPT_COMMAND] | is-empty) 'config and prompt variables are excluded'
}

def "test no names honours a custom exclude list" []: nothing -> nothing {
  $env.SBENV_DROP = 'x'
  let all: record = env --exclude [$.SBENV_DROP $.SBENV_NOT_SET]
  assert ($all | columns | where $it == SBENV_DROP | is-empty) 'excluded variables are dropped; missing ones are ignored'
}

# ——— env add ——————————————————————————————————————————————————————————————————

def "test add sets a variable and returns what it loaded" []: nothing -> nothing {
  assert equal (env add SBENV_ADD v) {SBENV_ADD: v} 'the loaded record is returned'
  assert equal $env.SBENV_ADD 'v' 'the variable is set in the caller'
}

def "test add merges input then merge then name" []: nothing -> nothing {
  let loaded: record = {SBENV_P: 1 SBENV_Q: 0} | env add SBENV_Q 2 --merge {SBENV_R: 3 SBENV_Q: 1}
  assert equal $loaded {SBENV_P: 1 SBENV_Q: 2 SBENV_R: 3} 'name/value beats --merge, which beats the input'
  assert equal [$env.SBENV_P $env.SBENV_Q $env.SBENV_R] [1 2 3] 'every variable is loaded'
}

def "test add default keeps an existing variable" []: nothing -> nothing {
  $env.SBENV_KEEP = 'old'
  assert equal (env add SBENV_KEEP new --default) null 'nothing to set returns nothing'
  assert equal $env.SBENV_KEEP 'old' 'existing values are kept'
}

def "test add default sets missing and null variables" []: nothing -> nothing {
  $env.SBENV_NULL = null
  let loaded: record = {SBENV_NULL: filled SBENV_NEW: n} | env add --default
  assert equal $loaded {SBENV_NULL: filled SBENV_NEW: n} 'null and missing variables are set'
  assert equal [$env.SBENV_NULL $env.SBENV_NEW] [filled n] 'both are loaded'
}

def "test add conversions register env conversions" []: nothing -> nothing {
  let conv: table = [[name to_string from_string]; [SBENV_LIST {|v| $v | str join ',' } {|s| $s | split row ',' }]]
  env add --conversions $conv | ignore
  assert equal ($env.ENV_CONVERSIONS.SBENV_LIST | columns | sort) [from_string to_string] 'stored without the name column'
  assert equal (do $env.ENV_CONVERSIONS.SBENV_LIST.from_string 'a,b') [a b] 'the stored closure works'
}

def "test add conversions keep existing conversions" []: nothing -> nothing {
  $env.ENV_CONVERSIONS = {SBENV_OLD: {from_string: {|s| $s } to_string: {|v| $v }}}
  env add --conversions [[name to_string from_string]; [SBENV_NEW {|v| $v } {|s| $s }]] | ignore
  assert equal ($env.ENV_CONVERSIONS | columns | sort) [SBENV_NEW SBENV_OLD] 'new conversions are added to the existing ones'
}

# ——— env sel ——————————————————————————————————————————————————————————————————

def "test sel selects variables into a record" []: nothing -> nothing {
  $env.SBENV_S1 = 1
  $env.SBENV_S2 = 2
  assert equal (env sel SBENV_S1 SBENV_S2) {SBENV_S1: 1 SBENV_S2: 2} 'selected variables form a record'
}

def "test sel ignores missing variables by default" []: nothing -> nothing {
  $env.SBENV_S1 = 1
  assert equal (env sel SBENV_S1 SBENV_NOPE | columns) [SBENV_S1 SBENV_NOPE] 'missing columns are null, not errors'
  assert error {|| env sel --optional=false SBENV_NOPE } 'optional=false raises'
}

# ——— env has ——————————————————————————————————————————————————————————————————

def "test has one name returns a bool" []: nothing -> nothing {
  $env.SBENV_H = 1
  assert equal (env has SBENV_H) true 'an existing variable'
  assert equal (env has SBENV_NOPE) false 'a missing variable'
}

def "test has ignores case unless asked" []: nothing -> nothing {
  $env.SBENV_H = 1
  assert equal (env has sbenv_h) true 'case-insensitive by default'
  assert equal (env has --ignore-case=false sbenv_h) false 'exact spelling with ignore-case=false'
}

def "test has several names return a list" []: nothing -> nothing {
  $env.SBENV_H = 1
  assert equal (env has SBENV_H SBENV_NOPE) [true false] 'positional names'
  assert equal ([SBENV_H SBENV_NOPE] | env has) [true false] 'piped names'
  assert equal ([SBENV_H] | env has) [true] 'a piped list always returns a list'
}

def "test has treats null as missing only when asked" []: nothing -> nothing {
  $env.SBENV_N = null
  assert equal (env has SBENV_N) true 'null still exists by default'
  assert equal (env has --nullable=false SBENV_N) false 'nullable=false treats null as missing'
  assert equal (env has --nullable=false sbenv_n) false 'also when matched case-insensitively'
}

def "test has without names raises" []: nothing -> nothing {
  assert error {|| env has } 'no names is an error'
}

# ——— env rm ———————————————————————————————————————————————————————————————————

def "test rm hides a variable" []: nothing -> nothing {
  $env.SBENV_RM = 1
  env rm SBENV_RM
  assert equal ($env.SBENV_RM? ) null 'the variable is gone'
}

# ——— env dotenv ———————————————————————————————————————————————————————————————

def "test dotenv returns a record of the variables" []: nothing -> nothing {
  let vars: record = with-dotenv $DOTENV {|f| env dotenv $f }
  assert equal $vars {A: '1' SPACED: 'x y' EQ: '1=2' SINGLE: q UNBALANCED: '"open'} 'parsed variables'
}

def "test dotenv no transpose returns a table" []: nothing -> nothing {
  let vars: table = with-dotenv "A=1\nB=2\n" {|f| env dotenv --no-transpose $f }
  assert equal $vars [[key value]; [A '1'] [B '2']] 'key/value rows'
}

def "test dotenv does not load by default" []: nothing -> nothing {
  with-dotenv "SBENV_DOT=1\n" {|f| env dotenv $f } | ignore
  assert equal ($env.SBENV_DOT?) null 'parsing alone loads nothing'
}

def "test dotenv load loads the variables" []: nothing -> nothing {
  let res: record = with-dotenv "SBENV_DOT=1\n" {|f| {vars: (env dotenv --load $f) loaded: $env.SBENV_DOT?} }
  assert equal $res.vars {SBENV_DOT: '1'} 'the record is returned'
  assert equal $res.loaded '1' 'and loaded'
}

def "test dotenv load with no transpose still loads" []: nothing -> nothing {
  let res: record = with-dotenv "SBENV_DOT=2\n" {|f| {vars: (env dotenv --load --no-transpose $f) loaded: $env.SBENV_DOT?} }
  assert equal $res.vars [[key value]; [SBENV_DOT '2']] 'the table is returned'
  assert equal $res.loaded '2' 'and the variables are loaded'
}

def "test dotenv of a file without variables is empty" []: nothing -> nothing {
  assert equal (with-dotenv "# only a comment\n\n" {|f| env dotenv $f }) {} 'an empty record'
}

def "test dotenv defaults to the current directory" []: nothing -> nothing {
  let vars: record = with-dotenv "SBENV_CWD=1\n" {|f| cd ($f | path dirname); env dotenv }
  assert equal $vars {SBENV_CWD: '1'} '.env in $env.PWD'
}

def "test dotenv of a missing file raises" []: nothing -> nothing {
  assert error {|| env dotenv /nonexistent/sbenv/.env } 'an unresolvable path is an error'
}
