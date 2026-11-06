# Data-first test runner: suites are plain .nu files, results are a table.
#
# Suites
# - A test is `def "test <name>" []` or any command carrying the `@test` attribute (`use std/testing *` makes
#   the attribute parse). Only commands *defined in the suite file* count: commands a suite imports are ignored,
#   even when their names start with `test`.
# - A description whose first word is `ignore` (`# ignore`, `# ignore: not ready`), or an `@ignore` attribute, reports
#   the test as skipped without running it.
# - `skip <reason>` inside a test aborts it and reports it as skipped (missing tool, wrong OS, no credentials, ...).
#
# Hooks (optional; named `def "before all"` etc. or marked `@before-all` etc.)
# - `before all`  runs once per child interpreter, before its tests; its output is the suite context.
# - `before each` receives the suite context as $in; its output is the test context (default: the suite context).
# - a test        receives the test context as $in (null when no hook produces one).
# - `after each`  receives the test context; it runs even when the test fails.
# - `after all`   receives the suite context, once per child interpreter, after its tests.
# Hooks declared with `def --env` can change the environment the tests see. With `--isolation test`
# (the default) every test gets its own child interpreter, so `before all`/`after all` run around each test.
#
# Isolation
# Discovery and execution happen in child interpreters started with `--no-config-file`, so suites can never
# poison each other or the invoking session. Children get a scrubbed environment (an allowlist plus the
# configured `env`/`passthrough`), the configured library directories as `--include-path`, and the effective
# configuration in `$env.NU_TEST`. With `sandbox: true`, each child also gets a throwaway HOME/XDG tree. Each
# test's literal command name is written into the child program: nushell has no string-eval, and a `$name` in
# command position evaluates to the string instead of calling it. Children run detached from the terminal
# (`setsid`), so Ctrl-C ends the run only once the current child exits; `timeout` bounds a hung child (the run warns
# once when the program is missing). Children's stdout is read for result rows only: whatever a suite prints while
# loading, or a test prints, is discarded.
#
# Configuration, lowest to highest precedence
#   1. built-in defaults (`test config --defaults`)
#   2. `$env.NU_TEST`: a record (or its nuon text), the global default/override; relative paths resolve from $env.PWD
#   3. the nearest `nutest.nuon` above the suite file (above $env.PWD for `paths`); relative paths resolve from its directory
#   4. command flags
# Scalars take the highest layer that sets them. `lib-dirs` and `passthrough` accumulate (most specific first),
# and `env` records merge. The directory holding this module is always appended to `lib-dirs`, so suites and
# seams can `use test`.

# nu-lint-ignore-file: missing_output_type, list_param_to_variadic
# (sandbox and exec results are genuinely `any`; internal helpers take lists built by the runner)

# ——— imports —————————————————————————————————————————————————————————————————

use std-rfc/pb
use style

# ——— constants ————————————————————————————————————————————————————————————————

# Marks a result row on a child's stdout; anything a test prints passes through untagged.
const ROW: string = '#NUTEST-ROW#'
const PROJECT_FILE: string = 'nutest.nuon'
# The library directory this module lives in, so children can resolve `use test`.
const HOME: path = path self ..
const HOOKS: list<string> = [before-all before-each after-each after-all]
const ISOLATION: list<string> = [test suite]
# The ignore marker: a description whose first word is `ignore`, alone or followed by `:` ("Ignores whitespace" is not one).
const IGNORE: string = r#'(?i)^\s*ignore(\s|:|$)'#
# Test names the runner can call (it writes them into the child program as bare words): no quotes, brackets, braces,
# pipes, semicolons, comments, carets, percent signs or `>` (a redirection), and no word starting with `$`.
const CALLABLE: string = r#'^[^'"`()\[\]{}|;#^%>\n]*$'#
const UNCALLABLE_WORD: string = '(^| )\$'
# A `def` line in suite source: the command name, double/single/back-quoted or bare. Double- and single-quoted names
# are captured with their quotes, escapes and adjacent segments (`"say \"hi\""`, `'it''s'`) included, so `from nuon`
# can read them exactly as the parser does; back-quoted names have no escapes.
const DEF_RX: string = r#'(?m)^[ \t]*(?:export[ \t]+)?def[ \t]+(?:--[\w-]+[ \t]+)*(?:(?<dq>"(?:[^"\\]|\\.)*"(?:"(?:[^"\\]|\\.)*")*)|(?<sq>'[^']*'(?:'[^']*')*)|`(?<bq>[^`]+)`|(?<bare>[^\s\[]+))'#
const DEFAULTS: record = {
  paths: [tests/suites] # Suite files or directories searched when no paths are given
  lib-dirs: [] # Extra `--include-path` directories for child interpreters
  isolation: test # Child interpreter per `test` (hermetic) or per `suite` (fast)
  depth: 3 # Maximum directory depth searched below each suite directory
  jobs: 1 # Tests run concurrently with `--isolation test`
  scrub: true # Start children from an allowlisted environment instead of the caller's
  passthrough: [] # Extra variable names (exact) kept when scrubbing
  env: {} # Variables set in every child (applied after scrubbing)
  sandbox: false # Give every runner child its own throwaway HOME/XDG tree (removed afterwards)
  timeout: 0sec # Kill a child that runs longer than this (0sec: no limit; needs the `timeout` program)
}
# Variables kept when scrubbing: enough to find programs, locate home/temp, and render text.
const KEEP: list<string> = [
  PATH Path HOME USER USERNAME LOGNAME SHELL TERM COLORTERM LANG LANGUAGE TZ TMPDIR TEMP TMP
  XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
  SYSTEMROOT SystemRoot WINDIR COMSPEC PATHEXT USERPROFILE APPDATA LOCALAPPDATA
]

# ——— suite helpers (exported for suites) ——————————————————————————————————————

# Abort the current test, reporting it as skipped instead of failed.
#
# For runtime conditions: a missing external tool, absent credentials, the wrong OS, ...
export def skip [
  reason: string # Why the test cannot run here; shown in the report
]: any -> any {
  error make --unspanned {msg: $"SKIP: ($reason)"}
}

# Run a closure against a throwaway sandbox directory, removing it afterwards (also on failure).
#
# The closure receives {root, home, config, data, cache, state, code}: `home` is `root`, the XDG directories live
# under it (`data` already contains the `nushell` directory that `std-rfc/kv` expects), and `code` is an empty
# scratch directory. Pass the record to `sandboxed` to run nu code with its environment pointed into the sandbox.
export def with-sandbox [
  action: closure # Receives the sandbox context record
]: nothing -> any {
  let ctx: record = new-sandbox
  let result: record = try { {value: (do $action $ctx)} } catch {|e| {error: $e} }
  rm --recursive --force $ctx.root
  if $result has error {
    # Rethrow with the original message (the span is lost, the failure and any SKIP are not).
    # (`drop nth 0`, not `skip 1`: `skip` is this module's own command here.)
    let rest: string = $result.error | error-text | lines | drop nth 0 | str join (char newline)
    error make --unspanned ({msg: $result.error.msg help: $rest} | compact --empty)
  }
  $result.value
}

# Run nu code in a child interpreter whose HOME and XDG directories point into a `with-sandbox` context.
#
# Parse-time paths derived from `$nu.home-dir`/`$nu.data-dir` land in the sandbox, so the module under test runs
# unmodified while the real session, data and config stay untouched. The child uses the same library
# directories and environment scrubbing as test children.
export def sandboxed [
  ctx: record # A `with-sandbox` context
  code: string # The nu program to run
  --prelude: string = '' # Prepended to the code, e.g. `use <module> *`
  --vars (-e): record = {} # Additional variables for the child (override the sandbox's)
  --pipe (-p) # Return the child's stdout parsed as nuon (error on non-zero exit) instead of the complete record
]: nothing -> any {
  let sandbox: record = $ctx | sandbox-vars | merge $vars
  [$prelude $code] | compact --empty | str join (char newline) | exec --vars=$sandbox --pipe=$pipe
}

# A fresh sandbox directory tree (see `with-sandbox`); the caller removes `root`.
def new-sandbox []: nothing -> record {
  let root: path = mktemp --directory --tmpdir nutest-sandbox-XXXXXX
  let ctx: record = {
    root: $root
    home: $root
    config: ($root | path join .config)
    data: ($root | path join .local share)
    cache: ($root | path join .cache)
    state: ($root | path join .local state)
    code: ($root | path join code)
  }
  mkdir $ctx.config ($ctx.data | path join nushell) $ctx.cache $ctx.state $ctx.code
  $ctx
}

# The variables that point a child's home and XDG directories into a sandbox.
def sandbox-vars []: record -> record {
  let ctx: record = $in
  {
    HOME: $ctx.home
    XDG_CONFIG_HOME: $ctx.config
    XDG_DATA_HOME: $ctx.data
    XDG_CACHE_HOME: $ctx.cache
    XDG_STATE_HOME: $ctx.state
  }
}

# ——— configuration ————————————————————————————————————————————————————————————

# Show the effective configuration for a location (default: the current directory).
#
# The record is exactly what child interpreters receive in `$env.NU_TEST`. `project` names the `nutest.nuon`
# that contributed, if any.
export def config [
  location?: path # A suite file or directory whose nearest project file applies
  --defaults # Return the built-in defaults only
  --lib-dirs (-I): list<path> # As for `test`
  --isolation: string@$ISOLATION # As for `test`
  --depth (-d): int # As for `test`
  --jobs (-j): int # As for `test`
  --no-scrub # As for `test`
  --sandbox # As for `test`
  --no-sandbox # As for `test`
]: nothing -> record {
  if $defaults { return $DEFAULTS }
  let flags: record = flag-layer --lib-dirs=$lib_dirs --isolation=$isolation --depth=$depth --jobs=$jobs --no-scrub=$no_scrub --sandbox=$sandbox --no-sandbox=$no_sandbox
  resolve ($location | default $env.PWD) $flags
}

# Run nu code in a child interpreter configured like a test child.
#
# Useful for debugging module resolution: `test exec 'use mymodule; scope modules | get name'`. Code may also be
# piped in.
export def exec [
  code?: string # The nu program to run (default: pipeline input)
  --config (-c): record # Effective configuration (default: `test config`)
  --vars (-e): record = {} # Additional variables for the child
  --pipe (-p) # Return stdout parsed as nuon (error on non-zero exit) instead of the complete record
]: oneof<nothing, string> -> any {
  let piped: oneof<nothing, string> = $in
  let program: string = $code
    | default $piped
    | default { error make --unspanned {msg: 'no code given' help: 'pass the code as an argument or pipe it in'} }
  let cfg: record = $config | default { resolve $env.PWD {} }
  let res: record = spawn $cfg $program $vars
  if not $pipe { return $res }
  if $res.exit_code != 0 {
    error make --unspanned {msg: $"child interpreter exited with code ($res.exit_code)" help: ($res.stderr | str trim)}
  }
  $res.stdout | from nuon
}

# ——— runner ———————————————————————————————————————————————————————————————————

# Run test suites and return their results as a table.
#
# Paths may be suite files or directories (searched recursively for `*.nu`, skipping `mod.nu` seams); with no
# paths, the configured `paths` are searched. Progress renders on stderr; the return value is pure data:
# `test | where status != ok`.
export def main [
  ...paths: path # Suite files or directories to search (default: the configured `paths`)
  --match (-m): string@_suite-stems = '' # Only run suites whose file stem matches this regex
  --test (-t): string@_test-names = '' # Only run tests whose command name matches this regex
  --isolation: string@$ISOLATION # Child interpreter per `test` (hermetic) or per `suite` (fast)
  --lib-dirs (-I): list<path> # Extra library directories for child interpreters
  --depth (-d): int # Maximum directory depth searched below each suite directory
  --jobs (-j): int # Tests run concurrently with `--isolation test`
  --no-scrub # Let children inherit the caller's environment
  --sandbox # Give every child a throwaway HOME/XDG tree
  --no-sandbox # Let children use the real HOME/XDG directories
  --strict (-s) # Raise an error when any test fails or errors (for CI and hooks)
  --verbose (-v) # Print the error under every failing test
  --debug (-D) # Print the effective configuration and generated child programs
]: nothing -> table<suite: string, name: string, status: string, duration: duration, error: oneof<nothing, string>, file: path> {
  let flags: record = flag-layer --lib-dirs=$lib_dirs --isolation=$isolation --depth=$depth --jobs=$jobs --no-scrub=$no_scrub --sandbox=$sandbox --no-sandbox=$no_sandbox
  let suites: list<path> = find-suites $paths $flags
    | where $match == '' or (($it | path parse).stem =~ $match)
  if ($suites | is-empty) {
    let searched: list<path> = $paths | default --empty { (resolve $env.PWD $flags).paths }
    let filter: string = if $match == '' { '' } else { $" whose stem matches --match '($match)'" }
    error make --unspanned {msg: 'no test suites matched' help: $"no suite files($filter) under: ($searched | str join ', ')"}
  }
  let started: datetime = date now
  # Colours (`config use-colors`) are decided once per run; children never see a terminal, so test output is plain.
  let opts: record = {test: $test verbose: $verbose debug: $debug colors: (style colors)}
  let runs: table<suite: path, cfg: record> = $suites | each {|suite| {suite: $suite cfg: (resolve $suite $flags)} }
  warn-unbounded ($runs | get cfg) $opts.colors
  let results: list = $runs | each {|r| run-suite $r.suite $r.cfg $opts } | flatten
  if (is-terminal --stderr) { pb clear }
  summarize $results ((date now) - $started) $strict $opts.colors
  $results | select suite name status duration error file
}

# Enumerate the commands a suite defines and their roles, in a child interpreter.
#
# Returns one row per test or hook. Imported commands are excluded even when named like tests.
export def discover [
  suite: path # Path to a suite file
  --config (-c): record # Effective configuration (default: resolved for the suite)
]: nothing -> table<name: string, role: string, ignore: bool> {
  let file: path = $suite | path expand
  let cfg: record = $config | default { resolve $file {} }
  let defined: list<string> = open --raw $file | defined-names
  # The result travels as a tagged row (as test results do), so whatever the suite prints while loading is ignored.
  let program: string = [
    $"source ($file | to nuon)"
    'scope commands | where type == custom | select name description attributes'
    '| update attributes { get --optional name | default [] } | to nuon --serialize | encode base64'
    $"| print $\"\\n($ROW)\($in\)\""
  ] | str join (char newline)
  let res: record = spawn $cfg $program {} --sandbox=$cfg.sandbox
  if $res.exit_code != 0 {
    error make --unspanned {msg: $"could not load suite ($file)" help: ($res.stderr | str trim)}
  }
  let payloads: list = $res.stdout | tagged | where ($it | describe) =~ '^(table|list)'
  if ($payloads | is-empty) {
    error make --unspanned {msg: $"could not load suite ($file)" help: 'the child interpreter reported no definitions'}
  }
  let found: table = $payloads | last
  # Definition order (the order of `def`s in the file), not scope order (alphabetical).
  $defined | uniq | each {|n| $found | where name == $n | get --optional 0 } | compact
  | each {|c| {name: $c.name role: (role $c) ignore: (($c.description | default '') =~ $IGNORE or 'ignore' in $c.attributes)} }
  | where role != null
}

const SEAM: string = r##'# Test seam: everything every suite in this directory needs, re-exported once.
#
# Suites load it with `use ../mod.nu *`. Import the module under test before anything that exports `skip`
# would shadow the builtin `skip` inside it (modules parsed after the seam see the runner's `skip`).
{module}
export use std/assert
export use test [ skip with-sandbox sandboxed ]
'##

const STUB: string = r##'# Test suite: {name}
use ../mod.nu *

# Optional hooks (see `help test`): define only the ones you need.
#
# def "before all" []: nothing -> any { }        # once per child interpreter; output = suite context
# def "before each" []: any -> any { }           # receives the suite context; output = test context
# def "after each" []: any -> nothing { }        # receives the test context; runs even if the test failed
# def "after all" []: any -> nothing { }         # receives the suite context

def "test {name} works" []: nothing -> nothing {
  assert equal (1 + 1) 2 "replace with a real assertion"
}
'##

# Scaffold a test layout: a project file, a seam, and suite stubs.
#
# Creates `nutest.nuon` in the current directory (unless one exists), the seam `<directory>/../mod.nu`, and one
# stub per suite name in `<directory>`. Existing files are left alone unless `--force` is given.
export def init [
  ...suites: string # Suite names (`.nu` is appended); default: the name of the current directory
  --directory (-d): path = tests/suites # Directory for the suites; the seam goes in its parent
  --module (-m): path # Module under test (directory with mod.nu, or a .nu file) for the seam to re-export
  --lib-dirs (-I): list<path> = [] # Library directories recorded in the project file
  --force (-f) # Overwrite existing files
]: nothing -> table<path: path, action: string> {
  let dir: path = $directory | path expand
  let seam: path = $dir | path dirname | path join mod.nu
  mkdir $dir
  let module_line: string = if $module == null { '' } else {
    let target: path = $module | path expand --strict
    $"\nexport use (relpath ($seam | path dirname) $target | to nuon)"
  }
  let project: record = {
    paths: [(relpath $env.PWD $dir)]
    lib-dirs: ($lib_dirs | each { relpath $env.PWD ($in | path expand) })
  }
  let names: list<string> = $suites | default --empty [($env.PWD | path basename)]
  [
    {path: ($env.PWD | path join $PROJECT_FILE) text: ($project | to nuon --indent 2)}
    {path: $seam text: ($SEAM | str replace '{module}' $module_line)}
    ...($names | each {|n| {path: ($dir | path join $"($n | str replace --regex '\.nu$' '').nu") text: ($STUB | str replace --all '{name}' $n)} })
  ] | each {|f|
    if ($f.path | path exists) and not $force { return {path: $f.path action: kept} }
    $f.text | save --force $f.path
    {path: $f.path action: written}
  }
}


# ——— configuration internals ——————————————————————————————————————————————————

def flag-layer [
  --lib-dirs: oneof<nothing, list<path>>
  --isolation: oneof<nothing, string>
  --depth: oneof<nothing, int>
  --jobs: oneof<nothing, int>
  --no-scrub
  --sandbox
  --no-sandbox
]: nothing -> record {
  if $sandbox and $no_sandbox { error make --unspanned {msg: '--sandbox and --no-sandbox are mutually exclusive'} }
  {
    lib-dirs: ($lib_dirs | each { path expand })
    isolation: $isolation
    depth: $depth
    jobs: $jobs
    scrub: (if $no_scrub { false })
    sandbox: (if $sandbox { true } else if $no_sandbox { false })
  } | compact-record | normalize-layer $env.PWD flags
}

def compact-record []: record -> record { record where value != null }

# Validate a partial configuration layer and make its paths absolute relative to `base`. `--internal` also admits the
# keys the runner adds to a resolved configuration (`resolved`, `project`).
def normalize-layer [base: path source: string --internal]: record -> record {
  let layer: record = $in
  let known: list<string> = $DEFAULTS | columns | if $internal { append [resolved project] } else { }
  let unknown: list<string> = $layer | columns | where $it not-in $known
  if ($unknown | is-not-empty) {
    error make --unspanned {
      msg: $"unknown test configuration key\(s) in ($source): ($unknown | str join ', ')"
      help: $"valid keys: ($DEFAULTS | columns | str join ', ')"
    }
  }
  if ($layer.isolation? != null) and ($layer.isolation not-in $ISOLATION) {
    error make --unspanned {msg: $"invalid isolation '($layer.isolation)' in ($source)" help: $"expected one of: ($ISOLATION | str join ', ')"}
  }
  # `path join` keeps an absolute right-hand side as is.
  for key in [scrub sandbox] {
    let v: any = $layer | get --optional $key
    if $v != null and ($v | describe) != bool {
      error make --unspanned {msg: $"invalid ($key) '($v)' in ($source)" help: 'expected true or false'}
    }
  }
  let t: any = $layer | get --optional timeout
  if $t != null and (($t | describe) != duration or $t < 0sec) {
    error make --unspanned {msg: $"invalid timeout '($t)' in ($source)" help: 'expected a duration such as 30sec (0sec: no limit)'}
  }
  for key in [depth jobs] {
    let v: any = $layer | get --optional $key
    if $v != null and (($v | describe) != int or $v < 1) {
      error make --unspanned {msg: $"invalid ($key) '($v)' in ($source)" help: 'expected an integer of at least 1'}
    }
  }
  let absolute: closure = {|p|
    let p: string = if ($p | str starts-with '~') { $p | path expand } else { $p }
    $base | path join $p | path expand
  }
  $layer
  | if $in.paths? != null { update paths { each {|p| do $absolute $p } } } else { }
  | if $in.lib-dirs? != null { update lib-dirs { each {|p| do $absolute $p } } } else { }
}

# The `$env.NU_TEST` layer: a record, or nuon text as received by a child interpreter.
def env-layer []: nothing -> record {
  let layer: record = match ($env.NU_TEST? | describe) {
    nothing => ({})
    string => ($env.NU_TEST | from nuon)
    $t if $t starts-with record => $env.NU_TEST
    $t => { error make --unspanned {msg: $"$env.NU_TEST must be a record, got ($t)"} }
  }
  # A child receives the complete configuration the runner resolved (`resolved: true` plus every key). Only that record
  # may carry the internal keys; in a user's layer they are unknown keys like any other.
  let resolved: bool = ($layer.resolved? | describe) == bool and $layer.resolved? and ($DEFAULTS | columns | all {|k| $k in $layer })
  $layer | normalize-layer $env.PWD '$env.NU_TEST' --internal=$resolved
}

# The nearest project file at or above a directory, if any.
def project-file [start: path]: nothing -> oneof<path, nothing> {
  let dir: path = $start | path expand | if ($in | path type) == file { path dirname } else { }
  generate {|d|
    let up: path = $d | path dirname
    if $up != $d { {out: $d next: $up} } else { {out: $d} }
  } $dir
  | each { path join $PROJECT_FILE }
  | where ($it | path expand | path type) == file
  | get --optional 0
}

def project-layer [file: oneof<path, nothing>]: nothing -> record {
  if $file == null { return ({}) }
  open --raw $file | from nuon | default {} | normalize-layer ($file | path dirname) $file | insert project $file
}

# Combine layers (lowest precedence first) into an effective configuration.
def combine [...layers: record]: nothing -> record {
  let merged: record = $layers | reduce --fold $DEFAULTS {|layer acc|
    $acc
    | merge ($layer | reject --optional lib-dirs passthrough env)
    | update lib-dirs { prepend ($layer.lib-dirs? | default []) }
    | update passthrough { prepend ($layer.passthrough? | default []) }
    | update env { merge ($layer.env? | default {}) }
  }
  $merged
  | update paths { path expand } # only the defaults can still be relative: they resolve from $env.PWD
  | update lib-dirs { append $HOME | path expand | uniq }
  | update passthrough { uniq }
  | insert resolved true
  | default null project
}

# Effective configuration for a suite (or directory) given flag overrides.
def resolve [location: path flags: record]: nothing -> record {
  let from_env: record = env-layer
  # A child receives an already-resolved configuration: use it as is, so grandchildren behave identically.
  if ($from_env.resolved? | default false) {
    return (combine-resolved $from_env $flags)
  }
  combine $from_env (project-layer (project-file $location)) $flags
}

def combine-resolved [base: record flags: record]: nothing -> record {
  $base
  | merge ($flags | reject --optional lib-dirs)
  | update lib-dirs { prepend ($flags.lib-dirs? | default []) | uniq }
}

# ——— suite discovery ——————————————————————————————————————————————————————————

def find-suites [paths: list<path> flags: record]: nothing -> list<path> {
  let roots: list<path> = if ($paths | is-not-empty) {
    $paths | each {|p|
      let full: path = $p | path expand
      if not ($full | path exists) { error make --unspanned {msg: $"no such suite file or directory: ($p)"} }
      $full
    }
  } else {
    let cfg: record = resolve $env.PWD $flags
    let found: list<path> = $cfg.paths | where ($it | path exists)
    if ($found | is-empty) {
      error make --unspanned {
        msg: 'no test suites found'
        help: $"searched the configured paths: ($cfg.paths | str join ', ') \(set `paths` in ($PROJECT_FILE) or $env.NU_TEST, or pass paths)"
      }
    }
    $found
  }
  let depth: int = $flags.depth? | default (resolve $env.PWD $flags).depth
  $roots | each {|r|
    match ($r | path type) {
      file => [$r]
      dir => (glob --no-dir --depth=$depth ($r | path join '**' '*.nu') | where ($it | path basename) != mod.nu | sort)
      _ => []
    }
  } | flatten | uniq
}

# Names a suite file defines with `def` (quoted or bare), regardless of what it imports.
def defined-names []: string -> list<string> {
  parse --regex $DEF_RX | each {|m|
    let quoted: oneof<string, nothing> = [$m.dq? $m.sq?] | compact --empty | get --optional 0
    if $quoted == null { return ([$m.bq? $m.bare?] | compact --empty | first) }
    # The parser's own reading of the literal (escapes, doubled quotes); failing that, the text between the quotes.
    try { $quoted | from nuon | into string } catch { $quoted | str substring 1..<(($quoted | str length) - 1) }
  }
}

# The runner role of a command: test, a hook, or null.
def role [cmd: record]: nothing -> oneof<string, nothing> {
  let hook: string = $cmd.name | str replace --all ' ' '-'
  if ($cmd.name | str starts-with 'test ') or 'test' in $cmd.attributes {
    'test'
  } else if $hook in $HOOKS {
    $hook
  } else {
    $cmd.attributes | where $it in $HOOKS | get --optional 0
  }
}

# ——— execution ————————————————————————————————————————————————————————————————

def run-suite [suite: path cfg: record opts: record]: nothing -> list {
  let stem: string = $suite | path parse | get stem
  let c: bool = $opts.colors
  print --stderr $"('[' | tint dark_gray_bold $c)($stem | tint cyan_bold $c)(']' | tint dark_gray_bold $c)"
  if $opts.debug { print --stderr ($cfg | to nuon --indent 2) }
  let annotate: closure = {|rows| $rows | each { insert suite $stem | insert file $suite } }
  let found: record = try { {cmds: (discover $suite --config=$cfg)} } catch {|e| {error: ($e | error-text)} }
  if $found has error {
    let row: record = {name: '(discover)' status: error duration: 0sec error: $found.error}
    render $row ($opts | update verbose true)
    return (do $annotate [$row])
  }
  let cmds: table = $found.cmds
  let hooks: record = $HOOKS | each {|h| {$h: ($cmds | where role == $h | get name)} } | into record
  let wanted: table = $cmds | where role == test | where $opts.test == '' or $it.name =~ $opts.test
  let ignored: list = $wanted | where ignore | each {|t| {name: $t.name status: skip duration: 0sec error: 'ignored'} }
  let runnable: table = $wanted | where not $it.ignore
  # A test is called by writing its name into the child program, so the name must parse as bare words.
  let callable: closure = {|n| $n =~ $CALLABLE and $n !~ $UNCALLABLE_WORD }
  let uncallable: list = $runnable | where not (do $callable $it.name) | each {|t|
    {name: $t.name status: error duration: 0sec error: "this name cannot be called: remove quotes, brackets, braces, | ; # ^ % > and words starting with $"}
  }
  let names: list<string> = $runnable | where {|t| do $callable $t.name } | get name
  let rows: list = match $cfg.isolation {
    suite => (run-child $suite $cfg $hooks $names $opts)
    test => {
      let total: int = $names | length
      $names | enumerate | par-each --keep-order --threads=([$cfg.jobs 1] | math max) {|t|
        if (is-terminal --stderr) and $cfg.jobs == 1 { pb set-idx $t.index $total }
        run-child $suite $cfg $hooks [$t.item] $opts
      } | flatten
      # `after all` failures repeat once per child under test isolation: report them once.
      | uniq-by name status error
    }
  }
  for row in ($rows | where name == '(after all)') { render $row $opts }
  for row in [...$ignored ...$uncallable] { render $row $opts }
  do $annotate [...$rows ...$ignored ...$uncallable]
}

# Run some of a suite's tests in one child interpreter; render and return their rows.
def run-child [suite: path cfg: record hooks: record names: list<string> opts: record]: nothing -> list {
  if ($names | is-empty) { return [] }
  let program: string = program $suite $hooks $names
  if $opts.debug { print --stderr $program }
  let res: record = spawn $cfg $program {} --sandbox=$cfg.sandbox
  let rows: list = $res.stdout | tagged | where ($it | describe) starts-with record
  # A child that dies (parse error, `exit`, crash) emits no row for the remaining tests: report each as an error.
  let missing: list<string> = $names | where $it not-in ($rows | get name)
  let crashed: list = $missing | each {|n|
    let why: string = if $res.exit_code == 124 and $cfg.timeout > 0sec { $"timed out after ($cfg.timeout)" } else { $"exited with code ($res.exit_code) before reporting" }
    {name: $n status: error duration: 0sec error: $"child interpreter ($why)\n($res.stderr | str trim)"}
  }
  let all: list = [...$rows ...$crashed]
  # `(after all)` rows are rendered by the caller, once per suite.
  for row in ($all | where name != '(after all)') { render $row $opts }
  $all
}

# The decoded payloads of the tagged lines on a child's stdout. A line that starts with the marker but does not decode
# is test output, not a row; untagged lines are ignored.
def tagged []: string -> list {
  lines
  | where ($it | str starts-with $ROW)
  | each {|l| try { $l | str substring ($ROW | str length).. | decode base64 | decode | from nuon } }
  | compact
}

# A hook chain as a pipeline over `$in` (`before each | other hook`); empty when there are no hooks.
def chain [names: list<string>]: nothing -> string { $names | str join ' | ' }

# The child program: source the suite, then run each test with its hooks and print one tagged row per test.
# Rows are nuon, base64-encoded so multi-line errors cannot break the line protocol.
def program [suite: path hooks: record names: list<string>]: nothing -> string {
  let before_all: string = if ($hooks.before-all | is-empty) { 'null' } else { $"null | (chain $hooks.before-all)" }
  let before_each: string = if ($hooks.before-each | is-empty) { '$__suite.ctx' } else { $"$__suite.ctx | (chain $hooks.before-each)" }
  let after_each: string = if ($hooks.after-each | is-empty) { 'null' } else { $"try { $ctx | (chain $hooks.after-each) | ignore; null } catch {|e| $e }" }
  let after_all: string = if ($hooks.after-all | is-empty) { '' } else {
    $"if $__suite.ok { try { $__suite.ctx | (chain $hooks.after-all) | ignore } catch {|e| __nutest_emit {name: '\(after all\)' status: error duration: 0sec error: \(__nutest_text $e\)} } }"
  }
  let tests: list<string> = $names | each {|n|
    let q: string = $n | to nuon
    $"do {
  let __start = date now
  let __res = if not $__suite.ok { __nutest_hook_row 'before all' $__suite.error } else {
    try {
      let ctx = do --env { ($before_each) }
      let __test = try { $ctx | ($n); null } catch {|e| $e }
      let __after = ($after_each)
      if $__test != null {
        if \($__test.msg | str starts-with 'SKIP: '\) { {status: skip error: \($__test.msg | str substring 6..\)} } else { {status: fail error: \(__nutest_text $__test\)} }
      } else if $__after != null {
        {status: error error: $\"after each failed: \(__nutest_text $__after\)\"}
      } else { {status: ok error: null} }
    } catch {|e| __nutest_hook_row 'before each' $e }
  }
  __nutest_emit \($__res | insert name ($q) | insert duration \(\(date now\) - $__start\)\)
}"
  }
  [
    $"source ($suite | to nuon)"
    # The leading newline puts the marker at a line start even after output without a trailing newline.
    $"def __nutest_emit [row: record] { print $\"\\n($ROW)\($row | to nuon | encode base64\)\" }"
    'def __nutest_text [e]: nothing -> string {'
    '  let d = $e.details? | default {msg: $e.msg labels: [] help: null inner: []}'
    '  [$d.msg ...($d.labels? | default [] | get --optional text | default []) $d.help? ...($d.inner? | default [] | get --optional msg | default [])]'
    '  | compact --empty | uniq | str join (char newline)'
    '}'
    'def __nutest_hook_row [hook: string e]: nothing -> record {'
    '  if ($e.msg | str starts-with "SKIP: ") { {status: skip error: ($e.msg | str substring 6..)} } else { {status: error error: $"($hook) failed: (__nutest_text $e)"} }'
    '}'
    $"let __suite = try { {ok: true ctx: \(do --env { ($before_all) }\)} } catch {|e| {ok: false error: $e} }"
    ...$tests
    $after_all
  ] | str join (char newline)
}

# Start a child interpreter for a configuration; returns the `complete` record.
def spawn [
  cfg: record
  program: string
  extra: record
  --sandbox # Run the child in a fresh sandbox (HOME/XDG) that is removed afterwards
]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  if $sandbox {
    let ctx: record = new-sandbox
    let res: record = spawn $cfg $program (($ctx | sandbox-vars) | merge $extra)
    rm --recursive --force $ctx.root
    return $res
  }
  let vars: record = $cfg.env | merge $extra | merge {NU_TEST: ($cfg | to nuon)}
  # The program goes through a file: as a `--commands` argument it would hit the OS argument-size limit at a few
  # hundred tests per suite.
  let script: path = mktemp --tmpdir nutest-XXXXXX.nu
  $program | save --force $script
  let res: record = spawn-script $cfg $vars $script
  rm --force $script
  $res
}

def spawn-script [cfg: record vars: record script: path]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  let args: list<string> = [
    --no-config-file --table-mode=none --error-style=plain
    $"--include-path=($cfg.lib-dirs | str join (char esep))"
    $script
  ]
  # Children get an empty stdin and, where `setsid` exists, no controlling terminal: a test that waits for input
  # (`input`, a prompt, a TUI) fails instead of hanging the run. `input` reads the terminal, not stdin, so an
  # empty stdin alone is not enough.
  let detach: list<string> = which --all setsid | where type == external | get --optional 0.path | each {|p| [$p --wait] } | default []
  let limit: list<string> = if $cfg.timeout > 0sec {
    timeout-program | each {|p| [$p --kill-after=5 $"($cfg.timeout / 1sec)"] } | default []
  } else { [] }
  let launch: list<string> = [...$detach ...$limit $nu.current-exe ...$args]
  if not $cfg.scrub { return (with-env $vars { '' | run-external ...$launch | complete }) }
  let keep: list<string> = $KEEP | append $cfg.passthrough
  let kept: record = $env | record where {|k v| $k in $keep or $k =~ '^LC_' }
  let env_bin: list = which --all env | where type == external
  if ($env_bin | is-not-empty) {
    # `env -i` builds the child's environment from scratch. `hide-env` cannot be relied on: once a `do --env` has
    # run anywhere up the call stack (common in tests and hooks), it silently stops hiding anything.
    let assignments: list<string> = $kept | merge $vars | items {|k v| $"($k)=($v | env-text)" }
    let command: list<string> = [...$detach ...$limit $env_bin.0.path '-i' ...$assignments $nu.current-exe ...$args]
    return ('' | run-external ...$command | complete)
  }
  # No `env` program (native Windows): hide what we can; see the caveat above.
  let hidden: list<string> = $env | columns | where {|k|
    $kept not-has $k and $k not-in [PWD FILE_PWD CURRENT_FILE config]
  }
  do { hide-env ...$hidden; with-env $vars { '' | run-external ...$launch | complete } }
}

# The `timeout` program that enforces a configured `timeout`, if there is one on PATH.
def timeout-program []: nothing -> oneof<path, nothing> {
  which --all timeout | where type == external | get --optional 0.path
}

# A configured `timeout` that cannot be enforced is said once per run, so the missing bound never passes unnoticed.
def warn-unbounded [cfgs: list<record> colors: bool]: nothing -> nothing {
  let limits: list<duration> = $cfgs | get timeout | where $it > 0sec | uniq
  if ($limits | is-not-empty) and (timeout-program) == null {
    let text: string = $limits | each { into string } | str join ', '
    print --stderr ($"warning: timeout ($text) is configured but no `timeout` program is on PATH: children run unbounded" | tint yellow $colors)
  }
}

# An environment value as the text an external program receives (lists joined like PATH).
# nu-lint-ignore: missing_in_type
def env-text []: any -> string {
  match ($in | describe) {
    $t if $t starts-with list => ($in | each { into string } | str join (char esep))
    $t if ($t starts-with record) or ($t starts-with table) => ($in | to nuon)
    _ => ($in | into string)
  }
}

# ——— reporting ————————————————————————————————————————————————————————————————

# Flatten a caught error into readable text: message, label texts, help, inner messages.
def error-text []: record -> string {
  let e: record = $in
  let d: record = $e.details? | default {msg: $e.msg}
  [$d.msg ...($d.labels? | default [] | get --optional text | default []) $d.help? ...($d.inner? | default [] | get --optional msg | default [])]
  | compact --empty
  | uniq # a label often repeats the message
  | str join (char newline)
}

# `style paint` with the run's colour decision (`opts.colors`, taken once in `main`), so every line renders alike.
def tint [code: string on: bool]: string -> string { style paint $code --colors=$on }

# Print one result row; `opts.verbose` adds the error text under failures (errors always show it).
def render [row: record opts: record]: nothing -> nothing {
  let c: bool = $opts.colors
  let color: string = match $row.status { ok => 'green' skip => 'yellow' _ => 'red' }
  let name: string = $row.name | str replace --regex '^test ' ''
  let reason: string = if $row.status == skip and $row.error != null { $" ($'— ($row.error)' | tint attr_dimmed $c)" } else { '' }
  let ms: float = ($row.duration / 1ms) | math round --precision 1
  print --stderr $"  ($'[($row.status)]' | tint $color $c) ($name) ($'($ms)ms' | tint attr_dimmed $c)($reason)"
  if ($opts.verbose or $row.status == error) and $row.status in [fail error] and $row.error != null {
    $row.error | lines | each { $"      ($in)" } | str join (char newline) | print --stderr $in
  }
}

def summarize [results: list elapsed: duration strict: bool colors: bool]: nothing -> nothing {
  let count: closure = {|s| $results | where status == $s | length }
  let failed: int = (do $count fail) + (do $count error)
  print --stderr ([
    ($'(do $count ok) passed' | tint green $colors)
    ($'($failed) failed' | tint red $colors)
    ($'(do $count skip) skipped' | tint yellow $colors)
    ($'in (($elapsed / 1sec) | math round --precision 2)s' | tint attr_dimmed $colors)
  ] | str join ', ')
  if $strict and $failed > 0 { error make --unspanned {msg: $"($failed) test\(s) failed"} }
}

# ——— path helpers —————————————————————————————————————————————————————————————

# Relative path from directory `from` to `to` (both absolute).
def relpath [from: path to: path]: nothing -> string {
  let a: list<string> = $from | path expand | path split
  let b: list<string> = $to | path expand | path split
  let common: int = $a | zip $b | take while {|p| $p.0? == $p.1? } | length
  let up: list<string> = 0..<(($a | length) - $common) | each { '..' }
  # `skip` here would be this module's own `skip`; slice instead.
  let rel: list<string> = [...$up ...($b | slice $common..)]
  if ($rel | is-empty) { '.' } else { $rel | path join }
}

# ——— completions ——————————————————————————————————————————————————————————————

# Suite files visible to the command line being completed: the path arguments typed so far, else the configured paths.
def _suites-on-line [context: string]: nothing -> list<path> {
  let typed: list<path> = $context | split row --regex '\s+' | drop nth 0 | where $it !~ '^-' and ($it | path exists)
  try { find-suites $typed {} } catch { [] }
}

def _suite-stems [context: string]: nothing -> list<string> {
  _suites-on-line $context | each { path parse | get stem } | uniq
}

def _test-names [context: string]: nothing -> list<string> {
  _suites-on-line $context | each { open --raw $in | defined-names | where $it starts-with 'test ' } | flatten | uniq | sort
}
