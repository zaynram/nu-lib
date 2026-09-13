# Smoke test for `time` against a scratch Timewarrior database: `nu time/tests/time.nu`.
const NU_LIB_DIRS = [(path self ../../..)]
use _internal/time
use std/assert

$env.TIMEWARRIORDB = mktemp --directory --suffix=-timew
let now: datetime = date now

assert equal (time active) null 'nothing tracked in a fresh database'
assert equal (time list) [] 'empty export'
assert equal (time stop) null 'stop without an open interval'

let a = time start '#repo' alpha --at=($now - 3hr)
assert equal $a.tags ['#repo' alpha] 'start returns the interval'
assert equal $a.end null 'open interval has no end'
assert equal (time active | get id) 1 'active is the open interval'

let b = time start beta --at=($now - 1hr)
assert equal $b.tags [beta] 'start closes the previous interval'
let rows = time list
assert equal ($rows | length) 2 'both intervals exported'
assert equal ($rows | where tags == [beta] | first | get end) null 'beta is still open'
assert ((($rows | where tags == ['#repo' alpha] | first | get span) - 2hr | math abs) < 1sec) 'span of the closed interval'

let s = time stop --at=($now - 10min)
assert ((($s.end - ($now - 10min)) | math abs) < 1sec) 'stop --at moves the end'
assert equal (time active) null 'nothing tracked after stop'

let m = time modify 1 --tags=[gamma] --annotate=note
assert equal $m.tags [gamma] 'modify replaces the tag set'
assert equal $m.annotation note 'modify annotates'
let m2 = time modify 1 --end=($now - 5min)
assert ((($m2.end - ($now - 5min)) | math abs) < 1sec) 'modify moves the end'

assert equal (time list --from=($now - 4hr) --to=$now | length) 2 'from/to range'
assert equal (time list --span=30min | length) 1 'span ending now'
assert equal (time list --from=($now - 4hr) --span=90min | length) 1 'from with span'
assert equal (time list --to=($now - 2hr) --span=90min | length) 1 'to with span'
assert equal (time list gamma | length) 1 'tag filter'
assert error { time list --to=$now } '--to alone is an error'

assert ('#repo' in (time tags | get name)) 'tags reads tags.data'
assert equal (time get dom.tracked.count | str trim) '2' 'raw passthrough'

rm --recursive --force $env.TIMEWARRIORDB
print 'time: ok'
