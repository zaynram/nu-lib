# `time` against a scratch Timewarrior database: `test time/tests/suites`.
use ../mod.nu *

def "before each" []: nothing -> record<db: path, now: datetime> {
  if (which timew | is-empty) { skip 'timew is not installed' }
  {db: (mktemp --directory --suffix=-timew) now: (date now)}
}
def "after each" []: record -> nothing { rm --recursive --force $in.db }

# Two intervals: `#repo alpha` from 3h to 1h ago, then `beta` from 1h ago until 10 min ago.
def seed [now: datetime]: nothing -> nothing {
  time start '#repo' alpha --at=($now - 3hr) | ignore
  time start beta --at=($now - 1hr) | ignore
  time stop --at=($now - 10min) | ignore
}

def "test fresh database" []: record -> nothing {
  $env.TIMEWARRIORDB = $in.db
  assert equal (time active) null 'nothing tracked'
  assert equal (time list) [] 'empty export'
  assert equal (time stop) null 'stop without an open interval'
}

def "test start closes the previous interval" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  let a = time start '#repo' alpha --at=($t.now - 3hr)
  assert equal $a.tags ['#repo' alpha] 'start returns the interval'
  assert equal $a.end null 'open interval has no end'
  assert equal (time active | get id) 1 'active is the open interval'
  let b = time start beta --at=($t.now - 1hr)
  assert equal $b.tags [beta] 'start closes the previous interval'
  let rows = time list
  assert equal ($rows | length) 2 'both intervals exported'
  assert equal ($rows | where tags == [beta] | first | get end) null 'beta is still open'
  assert ((($rows | where tags == ['#repo' alpha] | first | get span) - 2hr | math abs) < 1sec) 'span of the closed interval'
}

def "test stop at" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  time start beta --at=($t.now - 1hr) | ignore
  let s = time stop --at=($t.now - 10min)
  assert ((($s.end - ($t.now - 10min)) | math abs) < 1sec) 'stop --at moves the end'
  assert equal (time active) null 'nothing tracked after stop'
}

def "test modify" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  let m = time modify 1 --tags=[gamma] --annotate=note
  assert equal $m.tags [gamma] 'modify replaces the tag set'
  assert equal $m.annotation note 'modify annotates'
  let m2 = time modify 1 --end=($t.now - 5min)
  assert ((($m2.end - ($t.now - 5min)) | math abs) < 1sec) 'modify moves the end'
}

def "test list ranges and tag filter" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  time modify 1 --tags=[gamma] | ignore
  assert equal (time list --from=($t.now - 4hr) --to=$t.now | length) 2 'from/to range'
  assert equal (time list --span=30min | length) 1 'span ending now'
  assert equal (time list --from=($t.now - 4hr) --span=90min | length) 1 'from with span'
  assert equal (time list --to=($t.now - 2hr) --span=90min | length) 1 'to with span'
  assert equal (time list gamma | length) 1 'tag filter'
  assert error { time list --to=$t.now } '--to alone is an error'
}

def "test tags and passthrough" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  assert ('#repo' in (time tags | get name)) 'tags reads tags.data'
  assert equal (time get dom.tracked.count | str trim) '2' 'raw passthrough'
}
