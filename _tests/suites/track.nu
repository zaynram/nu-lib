# `track` against a scratch Timewarrior database, git repository and `td` stub: `test _tests/suites/track.nu`.
#
# The runner sandboxes HOME/XDG, so the universal kv table `track` is a throwaway one. `todo find` reaches `td`
# through a stub on PATH that logs its arguments and lists the tasks in `$env.TD_TASKS` (none by default), so
# no test can reach Todoist.
use track
use time
use hook
use std-rfc/kv *
use ../mod.nu *

const BRANCH: string = 'docs/hooks-placement-abort'

def "before each" []: nothing -> record<db: path, repo: path, name: string, dir: path, bin: path> {
  if (which timew | is-empty) { skip 'timew is not installed' }
  if (which git | is-empty) { skip 'git is not installed' }
  let dir: path = mktemp --directory --suffix=-track
  let repo: path = $dir | path join repo
  let bin: path = $dir | path join bin
  mkdir $repo $bin
  ^git -C $repo init -q
  ^git -C $repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ^git -C $repo switch -q -c $BRANCH
  stub-td $bin
  {db: ($dir | path join timew) repo: $repo name: ($repo | path basename) dir: $dir bin: $bin}
}
def "after each" []: record -> nothing { rm --recursive --force $in.dir }

# ——— helpers ——————————————————————————————————————————————————————————————————

# A `td` stub: appends its arguments to `$TD_LOG`, prints `$TD_TASKS` (JSON) for `task list`.
def stub-td [bin: path]: nothing -> nothing {
  let td: path = $bin | path join td
  r##'#!/bin/sh
echo "$*" >> "${TD_LOG:-/dev/null}"
if [ "$1 $2" = "task list" ] && [ -n "$TD_TASKS" ]; then printf '%s' "$TD_TASKS"; else printf '%s' '{"results":[]}'; fi
'## | save $td
  ^chmod +x $td
}

# Point the test's environment at the scratch database and stub, inside the repository.
def --env enter [t: record]: nothing -> nothing {
  $env.TIMEWARRIORDB = $t.db
  $env.TD_LOG = $t.dir | path join td.log
  $env.PATH = $env.PATH | prepend $t.bin
  cd $t.repo
}

def td-calls [t: record]: nothing -> list<string> {
  let log: path = $t.dir | path join td.log
  if ($log | path exists) { open --raw $log | lines } else { [] }
}

def task-json [...contents: string]: nothing -> string {
  {results: ($contents | enumerate | each {|it| {id: $"($it.index + 1)" content: $it.item description: '' priority: 1 projectId: p labels: [] url: u} })}
  | to json --raw
}

# ——— registration —————————————————————————————————————————————————————————————

def "test import registers the named hooks once" []: record -> nothing {
  let t = $in
  with-sandbox {|ctx|
    let hooks = sandboxed $ctx 'use track; use track; $env.config.hooks | to nuon --serialize' --pipe
    assert equal ($hooks.pre_execution | get name) ['track::sync'] 'one pre_execution hook named track::sync (T4)'
    assert equal ($hooks.env_change.PWD | get name) ['track::focus'] 'one env_change.PWD hook named track::focus'
  }
}

def "test a disabled hook is not added again" []: record -> nothing {
  let t = $in
  with-sandbox {|ctx|
    let code = 'use hook; hook edit (hook reference track::sync) --update {disabled: true} | ignore; use track; $env.config.hooks.pre_execution | to nuon --serialize'
    let hooks = sandboxed $ctx $code --prelude 'use track' --pipe
    assert equal ($hooks | length) 1 're-importing keeps the disabled hook alone'
  }
}

def "test the sync hook honours its disabled flag" []: nothing -> nothing {
  let ref: cell-path = hook reference track::sync --strict
  assert (hook test $ref --condition) 'enabled by default'
  hook edit $ref --update {disabled: true} | ignore
  assert not (hook test $ref --condition) 'disabled with hook edit'
}

def "test the pwd hook refreshes only when leaving the root" []: nothing -> nothing {
  let ref: cell-path = hook reference track::focus --strict
  $env.TRACK = {root: /w/a}
  assert not (hook test $ref --condition /w/a /w/a/src) 'a subdirectory keeps the focus'
  assert not (hook test $ref --condition /w /w/a) 'the root itself keeps the focus'
  assert (hook test $ref --condition /w/a /w/ab) 'a sibling sharing the prefix refreshes (T3)'
  assert (hook test $ref --condition /w/a /w) 'a parent refreshes'
  $env.TRACK = {root: null}
  assert (hook test $ref --condition /w /w/a) 'outside a repository any change refreshes'
  hide-env TRACK
  assert (hook test $ref --condition /w /w/a) 'no focus yet refreshes'
}

def "test the pwd hook honours its disabled flag" []: nothing -> nothing {
  let ref: cell-path = hook reference track::focus --strict
  hook edit $ref --update {disabled: true} | ignore
  assert not (hook test $ref --condition /w /tmp) 'disabled with hook edit'
}

# ——— focus ————————————————————————————————————————————————————————————————————

def "test focus in a repository" []: record -> nothing {
  let t = $in
  enter $t
  let f = track focus --refresh
  assert equal ($f | select root repo branch task) {root: $t.repo repo: $t.name branch: $BRANCH task: null} 'focus in a repository without a matching task'
  assert equal $f.head ($t.repo | path join .git HEAD) 'the HEAD file'
  assert equal $f.tags [$'#($t.name)' $BRANCH] 'tags fall back to the branch'
  assert equal (track focus) $f 'cached focus'
}

def "test focus is kept per shell" []: record -> nothing {
  let t = $in
  enter $t
  let f = track focus --refresh
  assert equal $env.TRACK $f 'cached in $env.TRACK (T5)'
  assert equal (kv list --universal --table=track) [] 'nothing shared in the universal store'
}

def "test focus without a refresh is null in a new shell" []: nothing -> nothing {
  assert equal (track focus) null 'no focus until the first refresh'
}

def "test focus on a detached head uses the short hash" []: record -> nothing {
  let t = $in
  enter $t
  let sha: string = ^git rev-parse HEAD | str trim
  ^git switch -q --detach HEAD
  assert equal (track focus --refresh | get branch) ($sha | str substring 0..<8) 'eight characters of the commit'
}

def "test focus outside a repository" []: record -> nothing {
  let t = $in
  enter $t
  track focus --refresh | ignore
  cd $t.dir
  let f = track focus --refresh
  assert equal ($f | reject matches) {root: null} 'only root, set to null (T6)'
  assert equal ($f.matches | columns) [$'($t.name)@($BRANCH)'] 'the match cache survives'
}

def "test focus tags the matched task" []: record -> nothing {
  let t = $in
  enter $t
  $env.TD_TASKS = task-json hooks-placement unrelated-work
  let f = track focus --refresh
  assert equal $f.task hooks-placement 'the best-matching task content'
  assert equal $f.tags [$'#($t.name)' hooks-placement] 'tagged with the task'
  assert ((td-calls $t | first) starts-with $'task list --all --json --project ($t.name)') 'tasks of the repository project'
}

def "test focus caches matches for an hour" []: record -> nothing {
  let t = $in
  enter $t
  track focus --refresh | ignore
  track focus --refresh | ignore
  assert equal (td-calls $t | length) 1 'the second refresh uses the cache'
  let key: string = $'($t.name)@($BRANCH)'
  $env.TRACK = $env.TRACK | update $.matches { update $key { update $.at ((date now) - 2hr) } }
  track focus --refresh | ignore
  assert equal (td-calls $t | length) 2 'an expired match runs todo find again'
}

def "test focus refresh re-enables tracking" []: record -> nothing {
  let t = $in
  enter $t
  kv set --universal --table=track disabled true
  track focus --refresh | ignore
  assert equal (kv get --universal --table=track disabled) null 'disabled is dropped (T2)'
}

# ——— sync —————————————————————————————————————————————————————————————————————

def "test sync starts and re-focuses on checkout" []: record -> nothing {
  let t = $in
  enter $t
  let f = track focus --refresh
  track sync
  assert equal (time active | get tags) $f.tags 'sync starts the interval'
  track sync
  assert equal (time list | length) 1 'same focus does not restart'
  sleep 1100ms # timew drops zero-length intervals, so let the first one age past a second
  ^git -C $t.repo switch -q -c feat/other
  track sync
  assert equal (time active | get tags) [$'#($t.name)' feat/other] 'checkout re-focuses on the next command (T1)'
  assert equal (time list | length) 2 'checkout starts a new interval'
}

def "test sync without a focus refreshes it first" []: record -> nothing {
  let t = $in
  enter $t
  track sync
  assert equal $env.TRACK.repo $t.name 'focus computed by sync'
  assert equal (time active | get tags) [$'#($t.name)' $BRANCH] 'and tracked'
}

def "test sync restarts when the open interval has other tags" []: record -> nothing {
  let t = $in
  enter $t
  time start --at=((date now) - 1hr) elsewhere | ignore
  track sync
  assert equal (time active | get tags) [$'#($t.name)' $BRANCH] 'the focus wins'
  assert equal (time list | length) 2 'the other interval is closed, not replaced'
}

def "test idle gap closes the abandoned interval" []: record -> nothing {
  let t = $in
  enter $t
  track focus --refresh | ignore
  track sync
  sleep 1100ms
  track sync # advances the stamp past the interval start
  let stamped: datetime = ls (time db | path join track.stamp) | first | get modified
  sleep 2200ms
  track sync --idle=2sec
  assert equal (time list | length) 2 'idle gap closes the abandoned interval and starts a new one'
  assert (((time list | where end != null | last | get end) - $stamped | math abs) < 1sec) 'abandoned interval ends at the stamp'
  assert equal (time active | get tags) [$'#($t.name)' $BRANCH] 'new interval keeps the focus tags'
}

def "test sync touches the stamp" []: record -> nothing {
  let t = $in
  enter $t
  track sync
  assert (time db | path join track.stamp | path exists) 'the stamp exists in the database root'
}

def "test outside a repository nothing changes" []: record -> nothing {
  let t = $in
  enter $t
  track focus --refresh | ignore
  track sync
  cd $t.dir
  assert equal (track focus --refresh | get root) null 'outside a repository'
  track sync
  assert equal (time list | length) 1 'the last focus keeps accruing'
  assert equal (time active | get tags) [$'#($t.name)' $BRANCH] 'with its tags'
}

def "test outside a repository sync does not ask git again" []: record -> nothing {
  let t = $in
  enter $t
  cd $t.dir
  track focus --refresh | ignore
  let log: path = $t.dir | path join git.log
  let git: path = $t.bin | path join git
  let real: path = which git | get $.0.path
  $'#!/bin/sh(char nl)echo "$*" >> "($log)"(char nl)exec "($real)" "$@"(char nl)' | save $git
  ^chmod +x $git
  track sync
  track sync
  assert not ($log | path exists) 'the cached {root: null} focus is not stale (T6)'
}

def "test while disabled sync does nothing" []: record -> nothing {
  let t = $in
  enter $t
  track focus --refresh | ignore
  kv set --universal --table=track disabled true
  track sync
  assert equal (time active) null 'no interval while disabled'
  track focus --refresh | ignore
  track sync
  assert equal (time active | get tags) [$'#($t.name)' $BRANCH] 'tracking resumes after a refresh'
}

def "test a timew failure disables tracking everywhere with one line" []: record -> nothing {
  let t = $in
  with-sandbox {|ctx|
    let db: path = $ctx.code | path join not-a-dir
    'x' | save $db
    let vars = {TIMEWARRIORDB: $db PATH: ($env.PATH | prepend $t.bin)}
    let res = sandboxed $ctx $"cd ($t.repo | to nuon); track sync; track sync" --prelude 'use track' --vars $vars
    assert equal $res.exit_code 0 'the command still succeeds'
    let lines: list<string> = $res.stderr | lines | where $it starts-with 'track:'
    assert equal ($lines | length) 1 $"one message, then silence: ($res.stderr)"
    assert ($lines.0? starts-with 'track: disabled until PWD changes (reason: ') 'the reason is shown'
    let shared = sandboxed $ctx 'use std-rfc/kv *; kv get --universal --table=track disabled | to nuon' --pipe
    assert equal $shared true 'another shell sees the disabled switch'
  }
}

def "test a deleted repository refreshes instead of failing" []: record -> nothing {
  let t = $in
  enter $t
  track focus --refresh | ignore
  cd $t.dir
  rm --recursive --force $t.repo
  track sync
  assert equal $env.TRACK.root null 'the stale focus is replaced'
}
