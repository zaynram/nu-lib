# `time` against a scratch Timewarrior database: `test _tests/suites/time.nu`.
use time
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
  let err: record = try { time list --to=$t.now; {} } catch {|e| $e }
  assert equal $err.details?.code? time::range::invalid_argument '--to alone is an error'
}

def "test tags and passthrough" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  assert ('#repo' in (time tags | get name)) 'tags reads tags.data'
  assert equal (time get dom.tracked.count | str trim) '2' 'raw passthrough'
}

# ——— more ——————————————————————————————————————————————————————————————————————

def "test db defaults next to the nushell data directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    let db = sandboxed $ctx 'time db | to nuon' --prelude 'use time' --pipe
    assert equal $db ($ctx.data | path join timewarrior) 'timewarrior beside $nu.data-dir'
    let set = sandboxed $ctx 'time db | to nuon' --prelude 'use time' --vars {TIMEWARRIORDB: /x/tw} --pipe
    assert equal $set /x/tw 'TIMEWARRIORDB wins'
  }
}

def "test tags of a fresh database is empty" []: record -> nothing {
  $env.TIMEWARRIORDB = $in.db
  assert equal (time tags) [] 'no tags.data yet'
}

def "test tags counts uses" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  time start alpha --at=($t.now - 5min) | ignore
  let counts: record = time tags | each {|r| {($r.name): $r.count} } | into record
  assert equal $counts {'#repo': 1 alpha: 2 beta: 1} 'one row per tag with its count'
}

def "test list rows are typed" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  time start open --at=($t.now - 5min) | ignore
  let rows = time list
  assert equal ($rows | columns) [id start end span tags annotation] 'the columns'
  assert equal ($rows | get id | sort) [1 2 3] 'ids'
  assert equal ($rows | where tags == [open] | first | get end) null 'the open interval has no end'
  assert equal ($rows | get start | each { describe } | uniq) [datetime] 'local datetimes'
  assert equal ($rows | get span | each { describe } | uniq) [duration] 'spans'
}

def "test list from alone ends now" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  assert equal (time list --from=($t.now - 2hr) | length) 2 'beta, and alpha overlapping the range'
  assert equal (time list --from=($t.now - 5min) | length) 0 'nothing after beta stopped'
}

def "test list passes hints and requires every tag" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  assert equal (time list '#repo' alpha | length) 1 'both tags'
  assert equal (time list '#repo' beta | length) 0 'not both tags'
  assert equal (time list :all | length) 2 'a hint passes through'
}

def "test today and week" []: record -> nothing {
  let t = $in
  let now: record = $t.now | into record
  if $now.hour == 0 and $now.minute < 10 { skip 'too close to midnight for :day' }
  $env.TIMEWARRIORDB = $t.db
  time start x --at=($t.now - 5min) | ignore
  assert equal (time today | get tags) [[x]] 'the interval of today'
  assert equal (time week | get tags) [[x]] 'and of this week'
}

def "test start without tags and in the future" []: record -> nothing {
  $env.TIMEWARRIORDB = $in.db
  assert equal (time start | get tags) [] 'an untagged interval'
  let err: record = try { time start --at=((date now) + 1hr) x; {} } catch {|e| $e }
  assert ($err.msg =~ '^timew start exited with code \d+$') $'the message names the subcommand: ($err.msg)'
  assert equal $err.details?.help? 'Time tracking cannot be set in the future.' 'timew stderr is the advice'
  assert equal $err.details?.code? time::tw::external_failure 'the external_failure code'
}

def "test stop returns the closed interval" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  time start beta --at=($t.now - 1hr) | ignore
  let s = time stop
  assert equal $s.tags [beta] 'the interval that was open'
  assert ($s.end != null) 'now closed'
}

def "test modify start and empty tags" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  seed $t.now
  let m = time modify 2 --start=($t.now - 4hr)
  assert ((($m.start - ($t.now - 4hr)) | math abs) < 1sec) 'modify moves the start'
  assert equal (time modify 1 --tags=[] | get tags) [] 'an empty tag set untags'
}

def "test modify an unknown id raises" []: record -> nothing {
  $env.TIMEWARRIORDB = $in.db
  let err: record = try { time modify 99 --annotate x; {} } catch {|e| $e }
  assert ($err.msg =~ '^timew annotate exited with code \d+$') $'the message names the subcommand: ($err.msg)'
  assert equal $err.details?.help? "ID '@99' does not correspond to any tracking." 'timew stderr is the advice'
}

def "test passthrough returns timew output" []: record -> nothing {
  $env.TIMEWARRIORDB = $in.db
  assert equal (time get dom.active | str trim) '0' 'raw text'
}
