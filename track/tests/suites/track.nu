# `track` against a scratch Timewarrior database and git repository: `test track/tests/suites`.
use ../mod.nu *

def "before each" []: nothing -> record<db: path, repo: path, name: string> {
  if (which timew | is-empty) { skip 'timew is not installed' }
  let repo: path = mktemp --directory --suffix=-track
  ^git -C $repo init -q
  ^git -C $repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ^git -C $repo switch -q -c docs/hooks-placement-abort
  {db: (mktemp --directory --suffix=-timew) repo: $repo name: ($repo | path basename)}
}
def "after each" []: record -> nothing { rm --recursive --force $in.db $in.repo }

def "test focus" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  cd $t.repo
  let f = track focus --refresh
  assert equal ($f | select repo branch task) {repo: $t.name branch: docs/hooks-placement-abort task: null} 'focus in a repository without a Todoist project'
  assert equal $f.tags [$'#($t.name)' docs/hooks-placement-abort] 'tags fall back to the branch'
  assert equal (track focus) $f 'cached focus'
}

def "test sync starts and re-focuses on checkout" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  cd $t.repo
  let f = track focus --refresh
  track sync
  assert equal (time active | get tags) $f.tags 'sync starts the interval'
  track sync
  assert equal (time list | length) 1 'same focus does not restart'
  sleep 1100ms # timew drops zero-length intervals, so let the first one age past a second
  ^git -C $t.repo switch -q -c feat/other
  track sync
  assert equal (time active | get tags) [$'#($t.name)' feat/other] 'checkout re-focuses on the next command'
  assert equal (time list | length) 2 'checkout starts a new interval'
}

def "test idle gap closes the abandoned interval" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  cd $t.repo
  track focus --refresh | ignore
  track sync
  sleep 1100ms
  track sync # advances the stamp past the interval start
  let stamped: datetime = ls (time db | path join track.stamp) | first | get modified
  sleep 2200ms
  track sync --idle=2sec
  assert equal (time list | length) 2 'idle gap closes the abandoned interval and starts a new one'
  assert (((time list | where end != null | last | get end) - $stamped | math abs) < 1sec) 'abandoned interval ends at the stamp'
  assert equal (time active | get tags) [$'#($t.name)' docs/hooks-placement-abort] 'new interval keeps the focus tags'
}

def "test outside a repository" []: record -> nothing {
  let t = $in
  $env.TIMEWARRIORDB = $t.db
  cd $t.repo
  track focus --refresh | ignore
  track sync
  cd /tmp
  assert equal (track focus --refresh | get root) null 'outside a repository'
  track sync
  assert equal (time list | length) 1 'outside a repository nothing changes'
}
