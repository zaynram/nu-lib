# `var` over the universal `std-rfc/kv` store: `test _tests/suites/var.nu`.
#
# Test children are sandboxed, so the universal store lives in a fresh temp data directory for every test.
use var
use ../mod.nu *

# Every test writes the universal store: each starts with this guard, which skips instead of touching a real data
# directory (`--no-sandbox`) and empties the sandboxed store. The runner's sandbox points `XDG_DATA_HOME` into a
# throwaway directory under the temp dir, and the data dir follows it; a data dir anywhere else is the real one.
# (A skip raised from a `before each` hook would be reported as an error.)
def guard-store []: nothing -> nothing {
  let data_home: string = $env.XDG_DATA_HOME? | default ''
  let in_temp: bool = $data_home != '' and ($data_home | str starts-with ($nu.temp-dir | path join ''))
  if not ($in_temp and ($nu.data-dir | str starts-with $data_home)) {
    skip 'needs the runner sandbox: the universal kv store would be the real one'
  }
  # start empty, also when the tests share one child (`--isolation suite`)
  var | columns | each {|key| var --drop $key } | ignore
}

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

def "test the store is sandboxed and empty" []: nothing -> nothing {
  guard-store
  assert ($nu.data-dir | str starts-with $env.XDG_DATA_HOME) 'the data dir is the sandbox one'
  assert equal (var) {} 'an empty store is an empty record'
  assert equal (var ls) [] 'and an empty table'
}

def "test set and get round trips" []: nothing -> nothing {
  guard-store
  for value in [1 'text' [1 2] {a: {b: 1}} false 1.5 2026-01-01] {
    assert equal (var item $value) $value $'setting returns the value (($value | describe))'
    assert equal (var item) $value $'getting returns it (($value | describe))'
  }
}

def "test a missing key is null" []: nothing -> nothing {
  guard-store
  assert equal (var nope) null 'nothing stored'
}

def "test piped input sets the value" []: nothing -> nothing {
  guard-store
  assert equal ([1 2] | var list) [1 2] 'the input is stored'
  assert equal (var list) [1 2] 'and read back'
}

def "test an explicit value wins over input" []: nothing -> nothing {
  guard-store
  assert equal ('piped' | var key 'explicit') explicit 'the positional value'
  assert equal (var key) explicit 'is stored'
}

def "test without a key the store is a record" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  var b [x] | ignore
  assert equal (var) {a: 1 b: [x]} 'every pair'
}

def "test drop removes a key and returns its value" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  var b 2 | ignore
  assert equal (var --drop a) 1 'the dropped value'
  assert equal (var) {b: 2} 'the rest stays'
  assert equal (var --drop a 5) null 'drop wins over a value; nothing left to drop'
  assert equal (var a) null 'and nothing is set'
}

def "test ls lists key value rows" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  var b {c: 2} | ignore
  assert equal (var ls) [[key value]; [a 1] [b {c: 2}]] 'a table'
}

def "test set returns the whole store" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  assert equal (var set b 2) {a: 1 b: 2} 'the store after setting'
}

def "test set from a record" []: nothing -> nothing {
  guard-store
  assert equal ({x: 1 y: false} | var set) {x: 1 y: false} 'every field is a pair'
}

def "test set from a table and a key in order" []: nothing -> nothing {
  guard-store
  assert equal ([[key value]; [t 7] [s 6]] | var set u 8 | columns) [t s u] 'input rows first, then the key'
  assert equal (var) {t: 7 s: 6 u: 8} 'all stored'
}

def "test set overwrites a key" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  assert equal (var set a 2) {a: 2} 'the new value'
}

def "test set with a key only stores null" []: nothing -> nothing {
  guard-store
  assert equal (var set k) {k: null} 'a null value'
}

def "test set silent returns nothing" []: nothing -> nothing {
  guard-store
  assert equal (var set --silent a 1) null 'no store record'
  assert equal (var a) 1 'but the pair is stored'
}

def "test set without pairs" []: nothing -> nothing {
  guard-store
  let e = caught { var set }
  assert equal $e.msg 'no key-value pairs were provided' 'no input and no key'
  assert equal $e.code 'var::set::invalid_argument' 'the derived code'
  assert equal (caught { [] | var set }).msg 'no key-value pairs were provided' 'an empty table'
  assert equal (var set --silent) null 'silently nothing'
}

def "test pop removes a key and returns its value" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  var b 2 | ignore
  assert equal (var pop a) 1 'the value'
  assert equal (var) {b: 2} 'the key is gone'
}

def "test pop without a key removes the last pair" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  var b 2 | ignore
  assert equal (var pop) 2 'the last listed pair'
  assert equal (var pop) 1 'then the one before'
  assert equal (var) {} 'empty'
}

def "test pop on an empty store is an error" []: nothing -> nothing {
  guard-store
  let e = caught { var pop }
  assert equal $e.msg 'there are no stored key-value pairs' 'nothing to pop'
  assert equal $e.code 'var::pop::not_found' 'the derived code'
}

def "test pop of a missing key is null" []: nothing -> nothing {
  guard-store
  var a 1 | ignore
  assert equal (var pop nope) null 'no error'
  assert equal (var) {a: 1} 'nothing removed'
}

def "test many pairs at once" []: nothing -> nothing {
  guard-store
  let pairs = 0..49 | each {|i| {key: $'k($i)' value: $i} }
  $pairs | var set --silent | ignore
  assert equal (var ls | length) 50 'every pair is stored'
  assert equal (var k49) 49 'the values are intact'
}
