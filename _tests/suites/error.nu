# `error raise`: `test _tests/suites/error.nu`.
use error
use ../mod.nu *

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

def "test raise with a message only" []: nothing -> nothing {
  let e = caught { error raise 'it broke' }
  assert equal $e.msg 'it broke' 'the message'
  assert equal [$e.code $e.help] [null null] 'no code or help'
  assert equal $e.labels [] 'unspanned'
  assert equal $e.inner [] 'no inner error without input'
}

def "test raise with a code" []: nothing -> nothing {
  assert equal (caught { error raise 'it broke' --code 'mymod::ctx::kind' }).code 'mymod::ctx::kind' 'the code'
}

def "test raise with advice" []: nothing -> nothing {
  assert equal (caught { error raise 'it broke' --advice 'try again' }).help 'try again' 'the advice is the help'
}

def "test raise leaves out empty code and advice" []: nothing -> nothing {
  let e = caught { error raise 'it broke' --code '' --advice '' }
  assert equal [$e.code $e.help] [null null] 'empty strings are compacted away'
}

def "test raise wraps a record input as the inner error" []: nothing -> nothing {
  let e = caught { {msg: 'the cause'} | error raise 'it broke' }
  assert equal ($e.inner | get msg) ['the cause'] 'one inner error'
}

def "test raise wraps a caught error as the inner error" []: nothing -> nothing {
  let cause = try { error make --unspanned {msg: 'the config file could not be read' help: 'the help of the cause'} } catch {|e| $e }
  let e = caught { $cause | error raise 'it broke' }
  assert equal ($e.inner | get msg) ['the config file could not be read'] 'the caught error'
  assert equal ($e.inner | get help) ['the help of the cause'] 'with its details'
}

def "test raise with labels returns a closure" []: nothing -> nothing {
  let span = (metadata 'here').span
  let raiser = error raise 'it broke' --code 'a::b' --labels [{text: 'right here' span: $span}]
  assert equal ($raiser | describe) closure 'nothing is raised yet'
  let e = caught $raiser
  assert equal $e.msg 'it broke' 'the closure raises the error'
  assert equal ($e.labels | get text) ['right here'] 'with the labels'
  assert equal ($e.labels | get span) [$span] 'and their spans'
  assert equal $e.code 'a::b' 'and the code'
}

def "test raise with labels keeps the inner error" []: nothing -> nothing {
  let raiser = {msg: 'the cause'} | error raise 'it broke' --labels [{text: x span: (metadata 'x').span}]
  assert equal ((caught $raiser).inner | get msg) ['the cause'] 'the input is captured by the closure'
}
