# Smoke test for `track` against a scratch Timewarrior database and git repository: `nu track/tests/track.nu`.
const NU_LIB_DIRS = [(path self ../../..)]
use _internal/track
use _internal/time
use std/assert

$env.TIMEWARRIORDB = mktemp --directory --suffix=-timew
let repo: path = mktemp --directory --suffix=-track
let name: string = $repo | path basename
^git -C $repo init -q
^git -C $repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
^git -C $repo switch -q -c docs/hooks-placement-abort
cd $repo

let f = track focus --refresh
assert equal ($f | select repo branch task) {repo: $name branch: docs/hooks-placement-abort task: null} 'focus in a repository without a Todoist project'
assert equal $f.tags [$'#($name)' docs/hooks-placement-abort] 'tags fall back to the branch'
assert equal (track focus) $f 'cached focus'

track sync
assert equal (time active | get tags) $f.tags 'sync starts the interval'
track sync
assert equal (time list | length) 1 'same focus does not restart'
sleep 1100ms # timew drops zero-length intervals, so let the first one age past a second

^git -C $repo switch -q -c feat/other
track sync
assert equal (time active | get tags) [$'#($name)' feat/other] 'checkout re-focuses on the next command'
assert equal (time list | length) 2 'checkout starts a new interval'

sleep 1100ms
track sync # advances the stamp past the interval start
let stamped: datetime = ls (time db | path join track.stamp) | first | get modified
sleep 2200ms
track sync --idle=2sec
assert equal (time list | length) 3 'idle gap closes the abandoned interval and starts a new one'
assert (((time list | where end != null | last | get end) - $stamped | math abs) < 1sec) 'abandoned interval ends at the stamp'
assert equal (time active | get tags) [$'#($name)' feat/other] 'new interval keeps the focus tags'

cd /tmp
assert equal (track focus --refresh | get root) null 'outside a repository'
track sync
assert equal (time list | length) 3 'outside a repository nothing changes'

rm --recursive --force $repo $env.TIMEWARRIORDB
print 'track: ok'
