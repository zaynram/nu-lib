# /work/dev/nu/command/mod.nu

# ——— definitions ——————————————————————————————————————————————————————————————

# Errors if the input record contains a non-zero exit code.
export def post-complete [
  desc: string = 'external command'
  # Descriptor of the external command that was called
  --then (-t): closure
  # Closure to invoke with `stdout` as the sole positional argument when the `exit_code` == 0
  --label (-l): oneof<record<text: string, span: record>, table<text: string, span: record>> = []
  # Labels to include in the error record as a record table
  --inner (-i): oneof<error, record>
  # Additional context or an error record to include in the `inner` detail
  --empty (-e): oneof<nothing, string> = '(no output)'
  # Value to use as the default for cases where stdout and/or stderr is empty
]: oneof<closure, record<stdout: string, stderr: string, exit_code: int>> -> oneof<nothing, any, error> {
  let result: record = match ($in | describe | str replace <.+ '') {
    record => ()
    closure if ($in | to nuon --serialize) =~ '\|\s*complete\s*}' => (do --capture-errors $in)
    closure => (do --capture-errors $in | complete)
    $t => { error make --unspanned $"unsupported input type: '($t)'" }
  } | default nan $.exit_code | default --empty $empty $.stdout $.stderr
  match $result {
    {exit_code: 0 stdout: $o} if $then != null => (do $then $o)
    {exit_code: 0 stdout: $o} => $o
    {exit_code: nan} => {
      error make --unspanned {
        msg: "unable to gather external command result"
        help: ($in | transpose k v | format pattern '{k} = {v}' | str join ', ')
      }
    }
    {exit_code: $c} if ($label | is-empty) => {
      error make --unspanned ($in | details $desc --inner=$inner)
    }
    {exit_code: $c} if ($label | describe) starts-with record => {
      error make ($in | details $desc --inner=$inner | insert $.label $label)
    }
    {exit_code: $c} => {
      error make ($in | details $desc --inner=$inner | insert $.labels [$label])
    }
  }
}

# Run an external command and return its `complete` record.
export def --wrapped attempt [
  command: string
  # Name or path of the external command to wrap
  ...rest: string
  # Arguments to pass to the external command
  --check (-c)
  # Raise an error on non-zero `exit_code`; otherwise return `stdout`
  --merge (-m)
  # Merge `stdout` and `stderr` together into `stdout`
]: oneof<nothing, string> -> oneof<string, record<stdout: string, stderr: string, exit_code: int>, error> {
  let p: path = which $command
    | if $in == [] { error make --unspanned $"command not found: '($command)'" } else { get $.0.path }
  match $merge { false => {|| ^$p ...$rest | complete } _ => {|| ^$p ...$rest out+err>| complete } }
  | if $check { post-complete $command } else { do $in }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def details [
  desc: string
  --inner: oneof<record, error>
]: [
  record<exit_code: int, stdout: any, stderr: any> -> record<msg: string, help: string>
  record<exit_code: int, stdout: any, stderr: any> -> record<msg: string, help: string, inner: list<any>>
] {
  format pattern $'[output]:(char nl){stdout}{stderr}'
  | str trim --right
  | wrap help
  | insert $.msg $"($desc | if (which $in) != [] { $'`($in)`' } else { }) exited with code ($in.exit_code)"
  | if $inner != null { insert $.inner [$inner] } else { }
}
