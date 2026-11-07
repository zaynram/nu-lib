# `env from-bash`: run a bash script and return (or load) the variables it sets.
#
# The owner's reimplementation of `bash-env` (github.com/zaynram/bash-env-nushell, a fork of
# tesujimath/bash-env-nushell, MIT). Upstream's `bash-env-json` script (which needs `jq`) is replaced by the small
# bash helper below, which only prints snapshots of bash's variables; comparing them happens here. The results
# match bash-env-json 0.10.1 except where that was wrong (see `_tests/suites/env.nu`).
#
# Runs `bash` (genuinely bash, not POSIX sh: the scripts it reads are bash) and the `env` program. This file
# imports nothing by bare name (only `../error`), so it parses without the library on the include path.

# ——— imports ——————————————————————————————————————————————————————————————————

use ../error

# ——— constants ————————————————————————————————————————————————————————————————

# The bash side. It prints NUL-terminated records on stdout: a snapshot is `=env`, the exported environment
# (`env -0`: `name=value`), `=set`, then every shell variable that is set (`name=value`; an array gives its first
# element), listed like upstream does (`set` in POSIX mode, which leaves out bash's dynamic variables). It takes
# one snapshot before the script and one after it, then one before and one after each function named in its
# arguments, and ends with `=done`. When the script or a function fails it prints `=error`, `phase=<function>`
# (empty for the script) and `status=<status>`, and stops. Each phase's stderr starts with a NUL, `=phase`
# and a NUL. Like upstream, the script text (stdin) is run with `eval` inside a function, with `extglob` on and
# stdout discarded: `declare`/`local` without `-g` stay local to that function and `return` ends the script. The
# function's status (its last command's, or the `return` status, which leaves the function at once) is checked at
# the top level, so `return N` with N ≠ 0 fails like a failing last command.
# The helper's own variables start with `__from_bash_`, and it calls bash's builtins through `builtin`: a script
# that defines a function named `printf`, `read`, `local`, `set`, `continue`, `return` or `exit` would otherwise
# replace them in the snapshots taken after it (a `read` function hung the snapshot loop; `env` is run by path).
const HELPER: string = r#'
builtin shopt -s extglob
__from_bash_env=$(builtin type -P env) || { builtin printf 'bash: env: command not found\n' >&2; builtin exit 127; }
__from_bash_snapshot() {
  builtin printf '=env\0'
  "$__from_bash_env" -0
  builtin printf '=set\0'
  builtin local __from_bash_line __from_bash_name
  while IFS= builtin read -r __from_bash_line; do
    __from_bash_name=${__from_bash_line%%=*}
    case $__from_bash_name in
      '' | [!a-zA-Z_]* | *[!a-zA-Z_0-9]* | "$__from_bash_line") builtin continue ;;
    esac
    if [[ -v $__from_bash_name ]]; then builtin printf '%s=%s\0' "$__from_bash_name" "${!__from_bash_name}"; fi
  done < <(builtin set -o posix; builtin set)
  builtin return 0
}
__from_bash_fail() { builtin printf '=error\0phase=%s\0status=%s\0' "$1" "$2"; builtin exit 1; }
__from_bash_source() { builtin eval "$(</dev/stdin)" >/dev/null; }
__from_bash_snapshot
builtin printf '\0=phase\0' >&2
__from_bash_source '' || __from_bash_fail '' "$?"
__from_bash_snapshot
for __from_bash_fn in "$@"; do
  __from_bash_snapshot
  builtin printf '\0=phase\0' >&2
  "$__from_bash_fn" >/dev/null || __from_bash_fail "$__from_bash_fn" "$?"
  __from_bash_snapshot
done
builtin printf '=done\0'
'#

const PREFIX: string = '__from_bash_'
# Variables bash manages by itself, never reported as the script's changes: BASH_LINENO, COLUMNS and LINES change
# between snapshots (as upstream); SHELLOPTS, BASHOPTS and POSIXLY_CORRECT hold bash's own options, which a `set -e`,
# `set -o posix` or `shopt` in the script changes, and which `--load` would otherwise hand to every later bash (an
# exported SHELLOPTS turns its options on at startup); the dynamic variables (RANDOM, SRANDOM, SECONDS, LINENO,
# EPOCHSECONDS, EPOCHREALTIME) are listed by `set` once a script has referenced them.
const INHIBITED: list<string> = [
  BASH_LINENO
  COLUMNS
  LINES
  SHELLOPTS
  BASHOPTS
  POSIXLY_CORRECT
  RANDOM
  SRANDOM
  SECONDS
  LINENO
  EPOCHSECONDS
  EPOCHREALTIME
]
# Variables Nushell manages itself (a `cd` in the script sets PWD/OLDPWD): returned, never loaded.
const UNLOADABLE: list<string> = [PWD OLDPWD FILE_PWD CURRENT_FILE]
const RETURN: list<string> = [merge env shellvars preserve]

# ——— helpers ——————————————————————————————————————————————————————————————————

# `name=value` records as a record, without the helper's own variables.
def to-vars []: list<string> -> record {
  parse --regex '(?s)^(?<name>[^=]+)=(?<value>.*)$'
  | where not ($it.name starts-with $PREFIX)
  | transpose --ignore-titles --header-row --as-record
  | default --empty {}
}

# The shell variables of a snapshot: the set variables that are not exported.
def shellvars [snapshot: record<env: record, set: record>]: nothing -> record {
  $snapshot.set | record each {|name value| if $snapshot.env has $name { null } else { {$name: $value} } }
}

# The changes from `before` to `after` for one kind of variable: new and changed values, and null for the
# variables that are no longer set at all (`set` holds every variable set afterwards, exported or not, so an
# unexported variable is not reported as removed from the environment). Exported functions and the inhibited
# variables are left out.
def changes [before: record after: record set: record]: nothing -> record {
  let changed: list = $after | items {|name value|
      if ($name starts-with BASH_FUNC_) or $name in $INHIBITED or ($before | get --optional $name) == $value { null } else { {$name: $value} }
    }
  let removed: list = $before | items {|name _|
      if ($name starts-with BASH_FUNC_) or $name in $INHIBITED or ($set has $name) { null } else { {$name: null} }
    }
  $changed ++ $removed | compact | into record
}

# What changed between two snapshots: `{env shellvars}`.
def compare [before: record after: record]: nothing -> record<env: record, shellvars: record> {
  let set: record = $after.env | merge $after.set
  {env: (changes $before.env $after.env $set) shellvars: (changes (shellvars $before) (shellvars $after) $set)}
}

# Text that bash wrote, which is binary when it is not valid UTF-8 (invalid bytes become U+FFFD).
def text []: oneof<string, binary> -> string {
  if ($in | describe) == binary { decode utf-8 } else { }
}

# What a failed phase (`{phase status}`: a function, or the script when `phase` is empty) puts in the error message:
# `what` failed, its exit `status`, and its `cause` (`: <text>`, or empty when bash said nothing). As upstream: a
# script's cause is its whole stderr with bash's location prefixes removed, a function's the first line of its
# stderr. The raise itself happens in `main`, so that the error code names this module and not a helper.
def failure-of [failure: record<phase: string, status: string> stderr: string]: nothing -> record<what: string, status: string, cause: string> {
  let phase: string = $failure.phase
  let err: string = $stderr | split row "\u{0}=phase\u{0}" | last
  # Bash prefixes its own messages with the location (`environment: line 3: `, `environment: eval: line 20: `,
  # `bash: line 27: `); the text after it is the cause. Only that prefix is removed, so a message that merely
  # contains "line" keeps its text.
  let strip: closure = {|l| $l | str replace --regex '^(?:[^:\s]+: )*line [0-9]+: ' '' }
  let cause: string = if $phase == '' {
    $err | lines | each $strip | str join (char newline) | str trim --right --char (char newline)
  } else {
    $err | lines | get 0? | default '' | do $strip $in
  }
  {
    what: (if $phase == '' { 'the script' } else { $"function '($phase)'" })
    status: $failure.status
    cause: (if $cause == '' { '' } else { $": ($cause)" })
  }
}

# ——— definitions —————————————————————————————————————————————————————————————

# Run a bash script and return the variables it changes, optionally loading the environment variables.
#
# The script is the piped text, `--content`, or the file at `file` (exactly one of them). It runs in a new `bash`
# that inherits this shell's environment; its stdout is discarded and it fails when its last command fails or it
# ends with `return N` (N ≠ 0). It is evaluated inside a bash function: `declare`/`local` without `-g` stay local,
# `return` (status 0) ends it early and keeps what it set, and `exit` is an error.
# The script runs in an `||` context, so a `set -e` inside it has no effect (as in bash-env): a failing command
# that is not the last one is not an error.
# Exported variables are the `env` changes, unexported ones the `shellvars` changes; a variable the script removes
# is null; bash's own option variables (SHELLOPTS, BASHOPTS, POSIXLY_CORRECT) and its dynamic variables (RANDOM,
# SRANDOM, SECONDS, LINENO, EPOCHSECONDS, EPOCHREALTIME) are never reported. Values are always
# strings, as bash has no types (an array gives its first element). `--return merge`
# (the default) returns both in one record (`env` wins), with null and empty values dropped unless `--keep-empty`;
# `preserve` returns `{env shellvars}` unchanged, plus `fn: {<function>: {env shellvars}}` with `--execute`, whose
# functions run in order after the script, each compared with the state just before it. `--load` loads the
# script's `env` changes (null for a removed variable), except PWD, OLDPWD, FILE_PWD and CURRENT_FILE; `load-env`
# turns PATH and every variable with an `ENV_CONVERSIONS` entry into its Nushell value. A `cd` in the script shows
# up as the returned PWD/OLDPWD; `--cd` makes the caller follow it (change to the script's final directory).
@example "read the variables a script exports" { 'export N=10' | env from-bash } --result {N: '10'}
@example "unexported variables are shell variables" { 'ABC=123' | env from-bash --return shellvars } --result {ABC: '123'}
@example "load the environment of a profile" { open --raw ~/.profile | env from-bash --load | ignore }
@example "capture what functions change" {
  "export A=0\nf() { export A=1; S=one; }" | env from-bash --execute [f]
} --result {env: {A: '0'} shellvars: {} fn: {f: {env: {A: '1'} shellvars: {S: one}}}}
export def --env main [
  file?: path # A bash script to run, when the text is neither piped nor given with `--content`
  --content (-c): string # The script text (the same as piping it)
  --execute: list<string> = [] # Functions to run after the script; returns their changes too (implies `--return preserve`)
  --return (-r): string@$RETURN # What to return: `merge` (default), `env`, `shellvars` or `preserve` (see above)
  --load (-l) # Load the script's environment changes into the caller
  --cd # Change to the directory the script ended in (its PWD), when it changed it
  --keep-empty (-k) # Keep removed (null) and empty variables in a `merge`, `env` or `shellvars` result
  --serialize (-s) # Return the result as NUON text
]: [
  nothing -> oneof<record, string>
  string -> oneof<record, string>
] {
  let texts: list<string> = [$in $content] | compact
  if ($texts | length) + ([$file] | compact | length) > 1 {
    error raise 'the script was given more than once' --with={
      kind: invalid_argument
      help: 'pipe its text, give --content, or give a file path: one of them'
    }
  }
  if $return != null and $return not-in $RETURN {
    error raise $"unknown --return '($return)'" --with={
      kind: invalid_argument
      help: $"expected one of: ($RETURN | str join ', ')"
    }
  }
  if $execute != [] and $return not-in [null preserve] {
    error raise $"--execute cannot be combined with --return '($return)'" --with={
      kind: invalid_argument
      help: '--execute returns every change (preserve)'
    }
  }
  let script: oneof<string, binary> = $texts | get 0? | default {
      let path: path = $file | default {
          error raise 'no script was given' --with={
            kind: invalid_argument
            help: 'pipe its text, or give --content or a file path'
          }
        }
      if not ($path | path exists) { error raise $"file not found: '($path)'" --kind not_found }
      open --raw $path
    }
  let bash: path = which bash
    | where type == external
    | get 0?.path
    | default { error raise '`bash` is not on PATH' --kind missing_dependency }
  let res: record = $script | ^$bash --noprofile --norc -c $HELPER bash ...$execute | complete
  let records: list<string> = $res.stdout | text | split row (char nul)
  let marks: list<int> = $records | enumerate | where ($it.item | str starts-with '=') | get index
  let sections: list<record<mark: string, items: list<string>>> = $marks
    | append ($records | length)
    | window 2
    | each {|w| {mark: ($records | get ($w | first)) items: ($records | slice (($w | first) + 1)..<($w | last))} }
  let failure: oneof<nothing, list<string>> = $sections | where mark == '=error' | get 0?.items
  if $failure != null {
    let f: record = failure-of ($failure | to-vars) ($res.stderr | text)
    error raise $"($f.what) failed with status ($f.status)($f.cause)" --kind external_failure
  }
  if ($sections | where mark == '=done' | is-empty) {
    let stderr: string = $res.stderr | text | str replace --all "\u{0}=phase\u{0}" '' | str trim
    error raise $"bash exited with status ($res.exit_code) before the variables were read" --with={
      kind: external_failure
      help: (
        [$stderr 'a script that calls `exit` ends bash early; `return` (with status 0) ends the script and keeps the variables'] | compact --empty | str join (char newline)
      )
    }
  }
  # Snapshots in pairs, before and after: the script first, then each function.
  let comparisons: list<record> = $sections
    | where mark in ['=env' '=set']
    | each {|section| $section.items | to-vars }
    | chunks 2
    | each {|vars| {env: ($vars | first) set: ($vars | last)} }
    | chunks 2
    | each {|pair| compare ($pair | first) ($pair | last) }
  let main: record = $comparisons | first
  if $load { $main.env | reject --optional ...$UNLOADABLE | load-env }
  if $cd and ($main.env.PWD? | default '') != '' { cd $main.env.PWD }
  let mode: string = if $execute != [] { 'preserve' } else { $return | default merge }
  let result: record = match $mode {
    preserve if $execute == [] => $main
    preserve => ($main | insert fn ($execute | zip ($comparisons | skip 1) | into record))
    merge => ($main.shellvars | merge $main.env)
    _ => ($main | get $mode)
  } | if $mode == preserve or $keep_empty { } else { compact --empty }
  if $serialize { $result | to nuon --serialize } else { $result }
}
