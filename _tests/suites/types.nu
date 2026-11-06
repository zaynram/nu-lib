# `types cell-path join`: `test _tests/suites/types.nu`.
use types
use ../mod.nu *

# The members of a cell-path as `[value optional insensitive]` rows.
def members []: cell-path -> table<value: any, optional: bool, insensitive: bool> { split cell-path }

def "test join appends bare segments" []: nothing -> nothing {
  assert equal ($.a | types cell-path join b 0) $.a.b.0 'a string and an int'
  assert equal ($.a | types cell-path join b | members) [[value optional insensitive]; [a false false] [b false false]] 'plain members by default'
}

def "test join onto the root path" []: nothing -> nothing {
  assert equal ($. | types cell-path join a) $.a 'the root has no members'
  assert equal ($. | types cell-path join) $. 'still the root'
}

def "test join without segments returns the input" []: nothing -> nothing {
  assert equal ($.a.b | types cell-path join) $.a.b 'unchanged'
  assert equal ($.a? | types cell-path join | members) [[value optional insensitive]; [a true false]] 'flags are kept'
}

def "test optional flag marks the new segments" []: nothing -> nothing {
  assert equal ($.a | types cell-path join -o b c | members | get optional) [false true true] 'only the joined members'
}

def "test insensitive flag marks the new string segments" []: nothing -> nothing {
  assert equal ($.a | types cell-path join -i b | members | get insensitive) [false true] 'only the joined members'
  assert equal ($.a | types cell-path join -i -o b | members | last) {value: b optional: true insensitive: true} 'both flags'
}

def "test record segments override the defaults" []: nothing -> nothing {
  let joined = $.a | types cell-path join -o {value: b optional: false insensitive: true} c | members
  assert equal ($joined | get 1) {value: b optional: false insensitive: true} 'the record decides its own flags'
  assert equal ($joined | get 2) {value: c optional: true insensitive: false} 'bare segments still get the defaults'
}

def "test record segments may hold an index" []: nothing -> nothing {
  assert equal ($.a | types cell-path join {value: 2 optional: true insensitive: false}) $.a.2? 'an int value'
}

def "test segments with spaces" []: nothing -> nothing {
  assert equal ($.a | types cell-path join 'b c' | members | get value) [a 'b c'] 'a member is not split'
}

def "test join rejects other segment types" []: nothing -> nothing {
  let float: any = 1.5
  assert error { $.a | types cell-path join $float } 'a float is not a member'
}
