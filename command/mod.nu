# Run external commands and turn their `complete` records into values or errors.

# ——— imports ——————————————————————————————————————————————————————————————————

use error

# ——— definitions ——————————————————————————————————————————————————————————————

# Return the stdout of a finished external command, or raise its output as an error when it failed.
#
# The input is a `complete` record, or a closure that runs the external command:
# - A closure is run as `do --ignore-errors $closure | complete`, so the external must be its last pipeline element.
# - A closure whose body already ends with `| complete` is run as is, and the record it returns is used.
# - A closure that produces no external output (a value, or an error swallowed by `--ignore-errors`, such as a
#   command that does not exist) raises "unable to gather external command result".
#
# On exit code 0 the result is stdout (`""` when the command printed nothing), or `do $then $stdout` with `--then`.
# Any other exit code raises "<desc> exited with code <n>" (with the name in backticks when `desc` is a command
# on PATH), whose help text is `[output]:` followed by stdout and stderr (each on its own lines), or by `--empty`
# when both are empty.
@category system
@example 'the stdout of a successful command' { {stdout: "hi\n" stderr: '' exit_code: 0} | post-complete } --result "hi\n"
@example 'transform the stdout' { {stdout: '1 2' stderr: '' exit_code: 0} | post-complete --then {|o| $o | split row ' ' } } --result ['1' '2']
export def post-complete [
  desc: string = 'external command'
  # Descriptor of the external command that was called (used in the error message)
  --then (-t): closure
  # Closure to invoke with `stdout` as the sole positional argument when the `exit_code` is 0
  --label (-l): oneof<record<text: string, span: record>, table<text: string, span: record>> = []
  # Label (a record) or labels (a table) to attach to the error, which makes it spanned
  --inner (-i): oneof<error, record>
  # Additional context or an error record to include in the `inner` detail
  --empty (-e): oneof<nothing, string> = '(no output)'
  # Text to show in the error help when the command printed nothing on stdout and stderr
]: oneof<closure, record<stdout: string, stderr: string, exit_code: int>> -> oneof<nothing, any, error> {
  let input: any;
  # the signature already rejects other input types, including records without the three fields
  let result: any = if ($input | describe) == closure { $input | run-captured } else { $input }
  if ($result.exit_code? | describe) != int {
    error raise 'unable to gather external command result' --with={
      kind: invalid_argument
      help: $"the closure must end with an external command that exists, or with `| complete`; it produced ($result | describe)"
    }
  }
  if $result.exit_code == 0 {
    let stdout: any = $result.stdout? | default ''
    return (if $then != null { do $then $stdout } else { $stdout })
  }
  let name: string = if (which $desc | where type == external) != [] { $'`($desc)`' } else { $desc }
  let help: string = $result | output-help --empty=$empty
  # Without labels `error raise` raises here; with them it returns the closure, which `do` runs with the spans intact.
  $inner | error raise $"($name) exited with code ($result.exit_code)" --with={
    kind: external_failure
    help: $help
    labels: ($label | append [])
  } | do $in
}

# Run an external command and return its `complete` record (or, with `--check`, its stdout).
#
# Put attempt's own flags before the command: `--check`/`--merge` are recognised anywhere in the arguments, so
# an external argument spelled the same must be quoted (`attempt foo "--check"`). Arguments that Nushell parses as
# non-strings (`true`, `false`) must be quoted too. String pipeline input is passed to the command's stdin;
# without input, the command inherits stdin.
@category system
@example 'run a command and keep its record' { attempt sh '-c' 'echo hi; exit 3' } --result {stdout: "hi\n" stderr: '' exit_code: 3}
@example 'return stdout, raising on a non-zero exit code' { attempt --check printf hi } --result hi
export def --wrapped attempt [
  command: string
  # Name or path of the external command to run (builtins and custom commands of the same name are ignored)
  ...rest: string
  # Arguments to pass to the external command
  --check
  # Raise an error on a non-zero `exit_code` (see `post-complete`); otherwise return `stdout`
  --merge
  # Merge `stderr` into `stdout` (`stderr` is then always empty)
]: oneof<nothing, string> -> oneof<string, record<stdout: string, stderr: string, exit_code: int>> {
  let input: any;
  let found: list = which --all $command | where type == external
  if $found == [] { error raise $"command not found: '($command)'" --kind not_found }
  let p: path = $found | get $.0.path
  let result: record = match [($input == null) $merge] {
    [true false] => (^$p ...$rest | complete)
    [true true] => (^$p ...$rest out+err>| complete)
    [false false] => ($input | ^$p ...$rest | complete)
    [false true] => ($input | ^$p ...$rest out+err>| complete)
  } | {stdout: $in.stdout stderr: ($in.stderr? | default '') exit_code: $in.exit_code}
  if $check { $result | post-complete $command } else { $result }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Run a closure and capture its external command's result (see `post-complete`); null when there is none.
def run-captured []: closure -> oneof<nothing, record> {
  let action: closure;
  if (view source $action) =~ '\|\s*complete\s*\}$' {
    do --ignore-errors $action
  } else {
    try { do --ignore-errors $action | complete } catch { null }
  }
}

# The help text of a failed command: `[output]:` followed by its stdout and stderr (the non-blank streams, each
# trimmed at the end and joined by a newline, so a stdout without a trailing newline does not run into stderr), or
# by `empty` when both are blank.
def output-help [--empty: oneof<nothing, string>]: record -> string {
  let result: record;
  let output: string = [($result.stdout? | default '') ($result.stderr? | default '')]
    | each { str trim --right }
    | compact --empty
    | if $in == [] { $empty | default '' } else { str join (char nl) }
  $"[output]:(char nl)($output)" | str trim --right
}
