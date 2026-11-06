# `path` extensions (rejoin, truncate, select, re-exported helpers): `test _tests/suites/path.nu`.
#
# Imported prefixed: `use path *` would import a `select` that shadows the builtin.
use path
use ../mod.nu *

# The details of the error raised by `action`, or null when it raised nothing.
def caught [action: closure]: nothing -> oneof<nothing, record> {
  try { do $action | ignore; null } catch {|e| $e.details }
}

# ——— path rejoin ——————————————————————————————————————————————————————————————

def "test rejoin collapses separators and appends segments" []: nothing -> nothing {
  assert equal ('a\b//c' | path rejoin d) 'a/b/c/d' 'mixed and repeated separators collapse to /'
}

def "test rejoin uses a custom separator" []: nothing -> nothing {
  assert equal ('a/b' | path rejoin --sep '\' c) 'a\b\c' 'every separator becomes --sep'
}

def "test rejoin without input joins the segments" []: nothing -> nothing {
  assert equal (path rejoin a b//c) 'a/b/c' 'segments alone are joined'
}

def "test rejoin of a single string normalizes it" []: nothing -> nothing {
  assert equal ('x\\y' | path rejoin) 'x/y' 'no segments: only the separators change'
}

def "test rejoin maps over a list" []: nothing -> nothing {
  assert equal ([a b\c] | path rejoin z) [a/z b/c/z] 'each item gets the segments appended'
  assert equal ([] | path rejoin z) [] 'an empty list stays empty'
}

def "test rejoin lets an absolute segment win" []: nothing -> nothing {
  assert equal ('/abs' | path rejoin /root) '/root' 'like path join, an absolute segment replaces the base'
}

def "test rejoin with nothing to join raises" []: nothing -> nothing {
  let e = caught { path rejoin }
  assert equal $e.msg 'nothing to join' 'no input and no segments is an error'
  assert equal $e.code 'path::rejoin::invalid_argument' 'the derived code'
}

# ——— path truncate ————————————————————————————————————————————————————————————

def "test truncate keeps the last segments by default" []: nothing -> nothing {
  assert equal ([a/b/c/d] | path truncate 2) [c/d] 'the default --from end keeps the tail'
}

def "test truncate from start keeps the first segments" []: nothing -> nothing {
  assert equal ([a/b/c/d] | path truncate 2 --from start) [a/b] '--from start keeps the head'
  assert equal ([a/b/c/d] | path truncate 2 --from s) [a/b] 'only the first character of --from matters'
}

def "test truncate with a negative count keeps everything" []: nothing -> nothing {
  assert equal ([a/b/c] | path truncate) [a/b/c] 'the default -1 keeps all segments'
}

def "test truncate past the length keeps everything" []: nothing -> nothing {
  assert equal ([a/b] | path truncate 5) [a/b] 'n larger than the path keeps it whole'
}

def "test truncate relative to a root" []: nothing -> nothing {
  assert equal ([/x/y/z/w] | path truncate --root /x) [y/z/w] 'paths are made relative to --root first'
  assert equal ([/x/y/z/w] | path truncate 1 --root /x --from start) [y] 'then truncated'
}

def "test truncate updates the name column of a table" []: nothing -> nothing {
  let rows: table = [[name size]; [a/b/c 1] [d/e 2]] | path truncate 1
  assert equal $rows [[name size]; [c 1] [e 2]] 'only name changes'
}

def "test truncate keeps the input order" []: nothing -> nothing {
  let input: list<string> = 1..30 | each {|i| $'dir($i)/file($i)' }
  assert equal ($input | path truncate 1) (1..30 | each {|i| $'file($i)' }) 'parallel truncation keeps order'
}

def "test truncate to zero segments raises" []: nothing -> nothing {
  let e = caught { [a/b] | path truncate 0 }
  assert equal $e.msg 'cannot keep zero segments' 'zero segments would be an empty path'
  assert equal $e.code 'path::truncate::invalid_argument' 'the derived code'
}

def "test truncate rejects an unknown from" []: nothing -> nothing {
  let e = caught { [a/b] | path truncate --from middle }
  assert equal $e.msg "unknown --from 'middle'" 'only start/end are valid'
  assert equal $e.code 'path::truncate::invalid_argument' 'the derived code'
}

# ——— path select ——————————————————————————————————————————————————————————————

def "test select on empty input raises the message" []: nothing -> nothing {
  let e = caught { [] | path select --message 'nothing here' }
  assert equal $e.msg 'nothing here' 'the custom message is raised'
  assert equal $e.code 'path::select::invalid_argument' "the code is given, since the message is the caller's"
  assert equal (caught { [] | path select }).msg 'no files to select from' 'the default message'
}

def "test select on empty input with optional returns nothing" []: nothing -> nothing {
  assert equal ([] | path select --optional) null 'optional empty input is a no-op'
  assert equal (null | path select --optional) null 'also for nothing'
}

# ——— re-exports ———————————————————————————————————————————————————————————————

def "test add prepends to PATH" []: nothing -> nothing {
  path add /sbpath/bin
  assert equal ($env.PATH | first) '/sbpath/bin' 'std path add is re-exported'
}

def "test std-rfc helpers are re-exported" []: nothing -> nothing {
  assert equal ('a/b.txt' | path with-extension md) 'a/b.md' 'with-extension'
  assert equal ('a/b.txt' | path with-stem c) 'a/c.txt' 'with-stem'
  assert equal ('a/b.txt' | path with-parent z) 'z/b.txt' 'with-parent'
}
