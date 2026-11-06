# `command post-complete` and `command attempt`: `test _tests/suites/command.nu`.
#
# Record input is pure; closures and `attempt` run small POSIX tools (`sh`, `printf`, `cat`), skipped when absent.
use command
use ../mod.nu *

# Skip unless `name` is an external command on PATH.
def need [name: string]: nothing -> nothing {
  if (which --all $name | where type == external | is-empty) { skip $"($name) is not installed" }
}

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

def done [stdout: string = '' stderr: string = '' exit_code: int = 0]: nothing -> record {
  {stdout: $stdout stderr: $stderr exit_code: $exit_code}
}

# ——— post-complete: record input ——————————————————————————————————————————————

def "test post complete returns stdout on success" []: nothing -> nothing {
  assert equal (done "out\n" | command post-complete) "out\n" 'stdout is returned as is'
}

def "test post complete ignores stderr on success" []: nothing -> nothing {
  assert equal (done out warn | command post-complete) out 'stderr of a successful command is dropped'
}

def "test post complete returns an empty string for empty successful output" []: nothing -> nothing {
  assert equal (done | command post-complete) '' 'no "(no output)" placeholder on success'
}

def "test post complete then transforms stdout" []: nothing -> nothing {
  assert equal (done '1 2' | command post-complete --then {|o| $o | split row ' ' }) ['1' '2'] '--then receives stdout'
  assert equal (done | command post-complete --then {|o| $o | describe }) string '--then receives "" for empty output'
}

def "test post complete then is not called on failure" []: nothing -> nothing {
  let e = caught { done x '' 1 | command post-complete --then {|o| error make --unspanned {msg: 'then ran'} } }
  assert equal $e.msg 'external command exited with code 1' 'the exit code error wins'
}

def "test post complete raises on a non zero exit code" []: nothing -> nothing {
  let e = caught { done "partial\n" "boom\n" 2 | command post-complete }
  assert equal $e.msg 'external command exited with code 2' 'default descriptor and exit code'
  assert equal $e.help "[output]:\npartial\nboom" 'stdout then stderr in the help text'
  assert equal $e.labels [] 'unlabelled errors are unspanned'
  assert equal $e.inner [] 'no inner error by default'
}

def "test post complete names the command in the message" []: nothing -> nothing {
  assert equal (caught { done '' x 1 | command post-complete 'my tool' }).msg 'my tool exited with code 1' 'a plain descriptor'
  need sh
  assert equal (caught { done '' x 1 | command post-complete sh }).msg '`sh` exited with code 1' 'a command on PATH is quoted'
}

def "test post complete keeps negative exit codes" []: nothing -> nothing {
  assert equal (caught { done '' x (-1) | command post-complete }).msg 'external command exited with code -1' 'any non-zero code fails'
}

def "test post complete shows a placeholder when the failure printed nothing" []: nothing -> nothing {
  assert equal (caught { done '' '' 3 | command post-complete }).help "[output]:\n(no output)" 'the default placeholder'
  assert equal (caught { done "  \n" '' 3 | command post-complete }).help "[output]:\n(no output)" 'whitespace-only output counts as empty'
  assert equal (caught { done '' '' 3 | command post-complete --empty 'silence' }).help "[output]:\nsilence" 'a custom placeholder'
  assert equal (caught { done '' '' 3 | command post-complete --empty=null }).help '[output]:' 'no placeholder'
}

def "test post complete placeholder only replaces fully empty output" []: nothing -> nothing {
  assert equal (caught { done '' "only err\n" 3 | command post-complete }).help "[output]:\nonly err" 'stderr alone is shown'
  assert equal (caught { done "only out\n" '' 3 | command post-complete }).help "[output]:\nonly out" 'stdout alone is shown'
}

def "test post complete includes the inner error" []: nothing -> nothing {
  let e = caught { done '' x 1 | command post-complete --inner {msg: 'while doing a thing'} }
  assert equal ($e.inner | get msg) ['while doing a thing'] 'the inner record becomes the only inner error'
}

def "test post complete accepts a caught error as inner" []: nothing -> nothing {
  let inner = try { error make --unspanned {msg: 'root cause'} } catch {|e| $e }
  let e = caught { done '' x 1 | command post-complete --inner $inner }
  assert equal ($e.inner | length) 1 'one inner error'
}

def "test post complete attaches a single label" []: nothing -> nothing {
  let span = (metadata 'here').span
  let e = caught { done '' x 1 | command post-complete --label {text: 'called here' span: $span} }
  assert equal ($e.labels | get text) ['called here'] 'a record is the error label'
  assert equal ($e.labels.0.span) $span 'the label keeps its span'
}

def "test post complete attaches a table of labels" []: nothing -> nothing {
  let labels = [{text: a span: (metadata 'a').span} {text: b span: (metadata 'b').span}]
  let e = caught { done '' x 1 | command post-complete --label $labels }
  assert equal ($e.labels | get text) [a b] 'a table is the error labels'
}

def "test post complete rejects incomplete records" []: nothing -> nothing {
  let partial: any = {stdout: x}
  assert error { $partial | command post-complete } 'a record without exit_code and stderr is rejected'
  let textual: any = {stdout: x stderr: '' exit_code: '0'}
  assert error { $textual | command post-complete } 'a non-integer exit_code is rejected'
}

def "test post complete rejects other input types" []: nothing -> nothing {
  let text: any = 'stdout'
  assert error { $text | command post-complete } 'a string is not a result'
  let nothing: any = null
  assert error { $nothing | command post-complete } 'nothing is not a result'
}

# ——— post-complete: closure input —————————————————————————————————————————————

def "test post complete runs a closure and returns its stdout" []: nothing -> nothing {
  need sh
  assert equal ({|| ^sh -c 'echo hi' } | command post-complete) "hi\n" 'the closure output is completed'
}

def "test post complete raises a failing closure instead of exiting" []: nothing -> nothing {
  need sh
  let e = caught { {|| ^sh -c 'echo out; echo err >&2; exit 3' } | command post-complete 'job' }
  assert equal $e.msg 'job exited with code 3' 'the exit code is reported'
  assert equal $e.help "[output]:\nout\nerr" 'stdout and stderr are captured'
}

def "test post complete accepts a closure that already completes" []: nothing -> nothing {
  need sh
  assert equal ({|| ^sh -c 'echo done' | complete } | command post-complete) "done\n" 'the returned record is used'
  let e = caught { {|| ^sh -c 'exit 4' | complete } | command post-complete }
  assert equal $e.msg 'external command exited with code 4' 'a failing record raises'
}

def "test post complete accepts a multi line closure ending in complete" []: nothing -> nothing {
  need sh
  let action = {||
    let script = 'echo multi'
    ^sh -c $script | complete
  }
  assert equal ($action | command post-complete) "multi\n" 'trailing whitespace before the brace is fine'
}

def "test post complete reports a closure without an external result" []: nothing -> nothing {
  let e = caught { {|| ^nu-lib-command-that-does-not-exist } | command post-complete }
  assert equal $e.msg 'unable to gather external command result' 'a missing command produces no result'
  assert str contains $e.help 'must end with an external command' 'the help says what the closure must do'
  assert equal (caught { {|| 'a value' } | command post-complete }).msg 'unable to gather external command result' 'a closure returning a value'
}

def "test post complete then works with closure input" []: nothing -> nothing {
  need sh
  assert equal ({|| ^sh -c 'printf 3' } | command post-complete --then {|o| $o | into int }) 3 '--then receives the closure stdout'
}

# ——— attempt ——————————————————————————————————————————————————————————————————

def "test attempt returns the complete record" []: nothing -> nothing {
  need sh
  assert equal (command attempt sh '-c' 'echo out; echo err >&2; exit 3') (done "out\n" "err\n" 3) 'stdout, stderr and exit code'
}

def "test attempt does not raise without check" []: nothing -> nothing {
  need sh
  assert equal (command attempt sh '-c' 'exit 9' | get exit_code) 9 'a failure is data'
}

def "test attempt check returns stdout" []: nothing -> nothing {
  need printf
  assert equal (command attempt --check printf hi) hi 'stdout of a successful command'
  assert equal (command attempt --check printf '') '' 'empty stdout is an empty string'
}

def "test attempt check raises on failure" []: nothing -> nothing {
  need sh
  let e = caught { command attempt --check sh '-c' 'echo bad >&2; exit 5' }
  assert equal $e.msg '`sh` exited with code 5' 'the command name is the descriptor'
  assert equal $e.help "[output]:\nbad" 'the output is the help text'
}

def "test attempt merge folds stderr into stdout" []: nothing -> nothing {
  need sh
  let r = command attempt --merge sh '-c' 'echo out; echo err >&2; exit 2'
  assert equal ($r | columns) [stdout stderr exit_code] 'the record keeps all three fields'
  assert equal $r (done "out\nerr\n" '' 2) 'stderr is empty and stdout holds both streams'
}

def "test attempt merge with check" []: nothing -> nothing {
  need sh
  assert equal (command attempt --merge --check sh '-c' 'echo out; echo err >&2') "out\nerr\n" 'merged stdout'
  assert equal (caught { command attempt --merge --check sh '-c' 'echo err >&2; exit 1' }).help "[output]:\nerr" 'merged output in the help'
}

def "test attempt passes string input to stdin" []: nothing -> nothing {
  need cat
  assert equal ('piped' | command attempt cat) (done piped) 'the input reaches the command'
  assert equal ('piped' | command attempt --check cat) piped 'with --check'
  assert equal ('piped' | command attempt --merge cat | get stdout) piped 'with --merge'
}

def "test attempt reports a missing command" []: nothing -> nothing {
  let e = caught { command attempt nu-lib-command-that-does-not-exist }
  assert equal $e.msg "command not found: 'nu-lib-command-that-does-not-exist'" 'the name is reported'
}

def "test attempt runs the external when a builtin has the same name" []: nothing -> nothing {
  need echo
  assert equal (command attempt echo hi) (done "hi\n") '`echo` is /bin/echo, not the builtin'
}

def "test attempt runs a command given by path" []: nothing -> nothing {
  need sh
  with-sandbox {|ctx|
    let script = $ctx.code | path join hello.sh
    "#!/bin/sh\necho \"hello $1\"\n" | save $script
    chmod +x $script
    assert equal (command attempt --check $script world) "hello world\n" 'an absolute script path'
  }
}

def "test attempt leaves short flags to the external command" []: nothing -> nothing {
  need sh
  assert equal (command attempt sh -c 'exit 3' | get exit_code) 3 '-c is the external flag, not --check'
  assert equal (command attempt sh -c 'echo "$0"' -m) (done "-m\n") '-m is an argument, not --merge'
}

def "test attempt passes quoted long flags through" []: nothing -> nothing {
  need sh
  assert equal (command attempt sh -c 'echo "$0"' '--check' | get stdout) "--check\n" 'a quoted flag is an argument'
}

def "test attempt takes its own flags after the command" []: nothing -> nothing {
  need sh
  assert error { command attempt sh -c 'exit 3' --check } '--check is recognised anywhere in the arguments'
}
