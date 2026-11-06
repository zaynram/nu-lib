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
  let err: record = caught {|| env has }
  assert equal $err.msg 'no variable names were provided' 'no names is an error'
  assert equal $err.details?.code? 'env::has::invalid_argument' 'the derived code'
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
  let err: record = caught {|| env dotenv /nonexistent/sbenv/.env }
  assert equal $err.msg "file not found: '/nonexistent/sbenv/.env'" 'an unresolvable path is an error'
  assert equal $err.details?.code? 'env::dotenv::not_found' 'the derived code'
}

def "test dotenv of an unreadable file raises with the cause" []: nothing -> nothing {
  with-sandbox {|ctx|
    # a directory exists, but cannot be read as a file
    let err: record = caught {|| env dotenv $ctx.code }
    assert equal $err.details?.code? 'env::dotenv::io' 'reading failed'
    assert equal $err.msg $"the variables in '($ctx.code)' could not be read" 'the path is named'
    assert equal ($err.details?.inner? | length) 1 'the cause is the inner error'
  }
}

# ——— env from-bash ————————————————————————————————————————————————————————————

# `env from-bash` runs `bash` (tests skip without it) and `env`. `_tests/fixtures/env/from-bash` holds a corpus of
# scripts with what bash-env (bash-env-json 0.10.1) returned for each; the replacement must match it exactly.
const CORPUS: path = $FIXTURES | path join env from-bash
const INHERITED: record = {SBFB_KEEP: keep SBFB_GONE: gone SBFB_UNEX: unex}

def need-bash []: nothing -> nothing {
  if (which bash | is-empty) { skip '`bash` is not installed' }
}

# The error `action` raises (fails when it raises none).
def caught [action: closure]: nothing -> record {
  try { do $action; error make --unspanned {msg: 'no error was raised'} } catch {|e| $e }
  | if $in.msg == 'no error was raised' { error make --unspanned {msg: 'expected an error'} } else { }
}

# The pinned case, with <PATH> and <PWD> resolved for this shell.
def pinned [case: string]: nothing -> record {
  let json = {|s: string| $s | to json | str substring 1..-2 }
  open --raw ($CORPUS | path join parity.nuon)
  | str replace --all '<PATH>' (do $json ($env.PATH | str join (char esep)))
  | str replace --all '<PWD>' (do $json $env.PWD)
  | from nuon
  | get $case
}

# Run a corpus script and compare with what bash-env returned: the same record, or a failure with the same cause.
def parity [case: string]: nothing -> nothing {
  need-bash
  let pin: record = pinned $case
  let file: path = $CORPUS | path join $"($case).sh"
  let run: closure = {|| with-env $INHERITED { env from-bash --return preserve --execute $pin.execute $file } }
  if $pin.error? == null {
    assert equal (do $run) $pin.output $'the pinned output of ($case).sh'
  } else {
    let err: record = caught $run
    assert equal $err.details?.code? 'env::from-bash::external_failure' 'a failing script'
    assert ($err.msg ends-with $pin.error) $'the pinned cause of ($case).sh: ($err.msg)'
  }
}

def "test from bash parity plain values" []: nothing -> nothing { parity plain }
def "test from bash parity special values" []: nothing -> nothing { parity special-values }
def "test from bash parity shell variables" []: nothing -> nothing { parity shellvars }
def "test from bash parity removed variables" []: nothing -> nothing { parity removed }
def "test from bash parity path" []: nothing -> nothing { parity path }
def "test from bash parity functions" []: nothing -> nothing { parity functions }
def "test from bash parity empty script" []: nothing -> nothing { parity empty }
def "test from bash parity comments and output only" []: nothing -> nothing { parity comments-only }
def "test from bash parity failing script" []: nothing -> nothing { parity failing }
def "test from bash parity syntax error" []: nothing -> nothing { parity syntax-error }
def "test from bash parity failing function" []: nothing -> nothing { parity failing-function }
def "test from bash parity cd" []: nothing -> nothing { parity cd }
def "test from bash parity return" []: nothing -> nothing { parity return }
def "test from bash parity allexport" []: nothing -> nothing { parity allexport }
def "test from bash parity exported function" []: nothing -> nothing { parity exported-function }

def "test from bash reads piped text" []: nothing -> nothing {
  need-bash
  assert equal ("export SBFB_N=10\nSBFB_X=1" | env from-bash) {SBFB_N: '10' SBFB_X: '1'} 'merge is the default'
}

def "test from bash return modes" []: nothing -> nothing {
  need-bash
  let script: string = "export SBFB_N=10\nSBFB_X=1"
  assert equal ($script | env from-bash --return env) {SBFB_N: '10'} 'env only'
  assert equal ($script | env from-bash --return shellvars) {SBFB_X: '1'} 'shell variables only'
  assert equal ($script | env from-bash --return preserve) {env: {SBFB_N: '10'} shellvars: {SBFB_X: '1'}} 'both, apart'
  assert equal ("export SBFB_X=e\nSBFB_X=s" | env from-bash) {SBFB_X: s} 'merge: an exported variable that stays exported'
}

def "test from bash merge prefers the environment" []: nothing -> nothing {
  need-bash
  let out: record = with-env {SBFB_E: e} { "SBFB_E=changed\nexport -n SBFB_U; SBFB_U=1" | env from-bash --return preserve }
  assert equal $out.env {SBFB_E: changed} 'assigning an exported variable changes the environment'
}

def "test from bash reads a file" []: nothing -> nothing {
  need-bash
  let vars: record = with-sandbox {|ctx|
    let file: path = $ctx.code | path join vars.sh
    'export SBFB_FILE=yes' | save $file
    env from-bash --return env $file
  }
  assert equal $vars {SBFB_FILE: yes} 'variables exported by the file'
}

def "test from bash content is the same as piping" []: nothing -> nothing {
  need-bash
  assert equal (env from-bash --content 'export SBFB_C=1') {SBFB_C: '1'} '--content is the script text'
}

def "test from bash drops removed and empty values unless asked" []: nothing -> nothing {
  need-bash
  let script: string = "unset SBFB_GONE\nexport SBFB_EMPTY=\nexport SBFB_SET=1"
  let pruned: record = with-env $INHERITED { $script | env from-bash }
  assert equal $pruned {SBFB_SET: '1'} 'null and empty values are dropped'
  let kept: record = with-env $INHERITED { $script | env from-bash --keep-empty --return env }
  assert equal $kept {SBFB_GONE: null SBFB_EMPTY: '' SBFB_SET: '1'} '--keep-empty keeps them'
}

def "test from bash serialize returns nuon" []: nothing -> nothing {
  need-bash
  let text: string = 'export SBFB_S=1' | env from-bash --serialize
  assert equal ($text | from nuon) {SBFB_S: '1'} 'NUON text of the result'
}

def "test from bash load sets the environment" []: nothing -> nothing {
  need-bash
  $env.SBFB_GONE = 'gone'
  let out: record = "export SBFB_LOADED=5\nSBFB_SHELL=1\nunset SBFB_GONE" | env from-bash --load
  assert equal $out {SBFB_LOADED: '5' SBFB_SHELL: '1'} 'the result is still returned'
  assert equal $env.SBFB_LOADED '5' 'exported variables are loaded'
  assert equal $env.SBFB_SHELL? null 'shell variables are not'
  assert equal $env.SBFB_GONE null 'a removed variable becomes null'
}

def "test from bash load converts PATH and registered conversions" []: nothing -> nothing {
  need-bash
  $env.ENV_CONVERSIONS = {SBFB_LIST: {from_string: {|s| $s | split row ':' } to_string: {|v| $v | str join ':' }}}
  let out: record = 'export PATH="/sbfb/bin:$PATH"; export SBFB_LIST=a:b; export SBFB_PLAIN=a:b' | env from-bash --load
  assert equal ($out.PATH | describe) string 'returned values stay strings'
  assert equal ($env.PATH | first) /sbfb/bin 'the loaded PATH is a list'
  assert equal $env.SBFB_LIST [a b] 'ENV_CONVERSIONS apply when loading'
  assert equal $env.SBFB_PLAIN 'a:b' 'other variables stay strings'
}

def "test from bash load leaves the directory alone" []: nothing -> nothing {
  need-bash
  let pwd: path = $env.PWD
  let out: record = "cd /\nexport SBFB_CD=1" | env from-bash --load
  assert equal $out.PWD / 'the change of directory is returned'
  assert equal [$env.PWD $env.SBFB_CD] [$pwd '1'] 'but PWD is not loaded'
}

def "test from bash cd follows the script into its final directory" []: nothing -> nothing {
  need-bash
  let pwd: path = $env.PWD
  let target: path = mktemp --directory --tmpdir sbfb-cd-XXXXXX
  let out: record = $"cd ($target)\nexport SBFB_CD=2" | env from-bash --cd
  assert equal ($env.PWD | path expand) ($target | path expand) "--cd changes to the script's final directory"
  assert equal $env.SBFB_CD? null 'without --load nothing else is loaded'
  cd $pwd
  "cd /\nexport SBFB_CD=3" | env from-bash --cd --load | ignore
  assert equal [$env.PWD $env.SBFB_CD] [/ '3'] '--cd and --load combine'
  cd $pwd
  "export SBFB_CD=4" | env from-bash --cd | ignore
  assert equal $env.PWD $pwd 'a script that does not cd leaves the directory alone'
  rm --recursive --force $target
}

def "test from bash execute compares each function with the state before it" []: nothing -> nothing {
  # bash-env 0.10.1 compared each function with every earlier snapshot: SBFB_GONE (and KEEP once f1 removed it)
  # came back as null for every later function, and `export -n` inside a function went unreported.
  need-bash
  let script: string = "unset SBFB_GONE\nSBFB_SV=top\nf1() { export SBFB_A=1; unset SBFB_KEEP; }\nf2() { unset SBFB_SV; }\nf3() { :; }\nf4() { export -n SBFB_A; }"
  let out: record = with-env $INHERITED { $script | env from-bash --execute [f1 f2 f3 f4] }
  assert equal $out.env {SBFB_GONE: null} 'the script'
  assert equal $out.fn.f1 {env: {SBFB_A: '1' SBFB_KEEP: null} shellvars: {}} 'f1'
  assert equal $out.fn.f2 {env: {} shellvars: {SBFB_SV: null}} 'f2 reports only its own removal'
  assert equal $out.fn.f3 {env: {} shellvars: {}} 'f3 changes nothing'
  assert equal $out.fn.f4 {env: {} shellvars: {SBFB_A: '1'}} 'unexporting moves the variable to the shell variables'
}

def "test from bash keeps a trailing equals sign" []: nothing -> nothing {
  # bash-env 0.10.1 dropped it from exported values (`x=` became `x`, `=` became empty).
  need-bash
  assert equal ("export SBFB_T=x=\nexport SBFB_U==" | env from-bash) {SBFB_T: 'x=' SBFB_U: '='} 'values are kept whole'
}

def "test from bash ignores inherited names bash cannot hold" []: nothing -> nothing {
  # bash-env 0.10.1 reported them as removed (null), so `--load` set them to null.
  need-bash
  let out: record = with-env {'sbfb-dash': 1 'sbfb.dot': 2} { 'export SBFB_A=1' | env from-bash --return preserve }
  assert equal $out.env {SBFB_A: '1'} 'names that are not bash identifiers pass through unchanged'
}

def "test from bash reads shell variables after IFS changes" []: nothing -> nothing {
  # bash-env 0.10.1 split its list of names with IFS, so a changed IFS hid every shell variable.
  need-bash
  assert equal ("IFS=,\nSBFB_S=1" | env from-bash --return shellvars) {IFS: ',' SBFB_S: '1'} 'all shell variables'
}

def "test from bash does not report its own variables under allexport" []: nothing -> nothing {
  # bash-env 0.10.1 exported its own variables (_capture_env, _capture_shellvars) when a script left `set -a` on.
  need-bash
  let out: record = "set -a\nSBFB_X=1\nf() { SBFB_Y=2; }" | env from-bash --execute [f]
  assert equal $out.env {SBFB_X: '1'} 'only the script variable'
  assert equal $out.fn.f.env {SBFB_Y: '2'} 'only the function variable'
}

def "test from bash works under nounset" []: nothing -> nothing {
  # bash-env-json 0.10.1 failed on its own unset variables when a script left `set -u` on.
  need-bash
  let out: record = "set -u\nexport SBFB_U=1\ng() { export SBFB_G=1; }" | env from-bash --execute [g]
  assert equal [$out.env $out.fn.g.env] [{SBFB_U: '1'} {SBFB_G: '1'}] 'variables are read'
}

def "test from bash reads the environment after PATH loses env" []: nothing -> nothing {
  # bash-env-json 0.10.1 ran `env` through PATH, so a script that replaced PATH returned no environment changes.
  need-bash
  assert equal ("export PATH=/sbfb/none\nexport SBFB_B=1" | env from-bash) {PATH: /sbfb/none SBFB_B: '1'} 'both changes'
}

def "test from bash needs neither jq nor more than bash and env" []: nothing -> nothing {
  need-bash
  let out: record = with-sandbox {|ctx|
    let bin: path = $ctx.code | path join bin
    mkdir $bin
    for tool in [bash env] { ^ln -s (which $tool | get 0.path) ($bin | path join $tool) }
    with-env {PATH: [$bin]} { 'export SBFB_A=1' | env from-bash }
  }
  assert equal $out {SBFB_A: '1'} 'bash and env are enough'
}

def "test from bash failing script raises" []: nothing -> nothing {
  need-bash
  let err: record = caught {|| "export SBFB_A=1\nfalse" | env from-bash }
  assert equal $err.details?.code? 'env::from-bash::external_failure' 'the failure code: the module, with no command for main'
  assert equal $err.msg 'the script failed with status 1' 'no stderr, no cause'
}

def "test from bash failing function names it" []: nothing -> nothing {
  need-bash
  let err: record = caught {|| 'f() { return 4; }' | env from-bash --execute [f] }
  assert equal $err.msg "function 'f' failed with status 4" 'the function and its status'
}

def "test from bash exit raises" []: nothing -> nothing {
  need-bash
  let err: record = caught {|| "export SBFB_A=1\nexit 0" | env from-bash }
  assert equal $err.details?.code? 'env::from-bash::external_failure' 'exit stops bash before the variables are read'
  assert equal $err.msg 'bash exited with status 0 before the variables were read' 'the message says where bash stopped'
  assert str contains $err.details?.help? '`exit`' 'the advice names the likely cause'
}

def "test from bash rejects several scripts" []: nothing -> nothing {
  for action in [
    {|| 'A=1' | env from-bash /sbfb/x.sh }
    {|| 'A=1' | env from-bash --content 'B=1' }
    {|| env from-bash --content 'B=1' /sbfb/x.sh }
  ] {
    let err: record = caught $action
    assert equal $err.details?.code? 'env::from-bash::invalid_argument' 'one script at a time'
    assert equal $err.msg 'the script was given more than once' 'the message says what was wrong'
  }
}

def "test from bash without a script raises" []: nothing -> nothing {
  let err: record = caught {|| env from-bash }
  assert equal $err.details?.code? 'env::from-bash::invalid_argument' 'no text and no path'
  assert equal $err.msg 'no script was given' 'the message'
  assert str contains $err.details?.help? '--content' 'the advice lists the ways to give one'
}

def "test from bash missing file raises" []: nothing -> nothing {
  let err: record = caught {|| env from-bash /sbfb/missing.sh }
  assert equal $err.details?.code? 'env::from-bash::not_found' 'the file code'
  assert equal $err.msg "file not found: '/sbfb/missing.sh'" 'the path is named'
}

def "test from bash unknown return raises" []: nothing -> nothing {
  let err: record = caught {|| 'A=1' | env from-bash --return everything }
  assert equal $err.details?.code? 'env::from-bash::invalid_argument' 'an unknown mode'
  assert equal $err.msg "unknown --return 'everything'" 'the mode is named'
  assert str contains $err.details?.help? 'merge, env, shellvars, preserve' 'the advice lists the modes'
}

def "test from bash execute takes only preserve" []: nothing -> nothing {
  let err: record = caught {|| 'f() { :; }' | env from-bash --execute [f] --return env }
  assert equal $err.details?.code? 'env::from-bash::invalid_argument' '--execute with another --return'
  assert equal $err.msg "--execute cannot be combined with --return 'env'" 'the message names the flags'
  need-bash
  assert equal ('f() { :; }' | env from-bash --execute [f] --return preserve | columns) [env shellvars fn] 'preserve is allowed'
}

def "test from bash without bash raises" []: nothing -> nothing {
  let err: record = with-sandbox {|ctx| with-env {PATH: [$ctx.code]} { caught {|| 'A=1' | env from-bash } } }
  assert equal $err.details?.code? 'env::from-bash::missing_dependency' 'bash is looked up on PATH'
}
