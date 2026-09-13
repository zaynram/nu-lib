# Smoke test for `todo`: offline matcher, live reads, and opt-in live writes (`WARRIOR_TASK_WRITE=1`).
const NU_LIB_DIRS = [(path self ../../..)]
use _internal/todo
use std/assert

# ——— matcher (offline) ———————————————————————————————————————————————————————

let rows = [[id content url]; [1 hooks-placement u1] [2 nu-over-bash-hooks u2] [3 generator-migration u3]]
assert equal ($rows | todo find hooks-placement | select content score) {content: hooks-placement score: 1.0} 'exact match'
assert equal ($rows | todo find docs/hooks-placement-abort | get content) hooks-placement 'token overlap'
assert equal ($rows | todo find trust-generator-v3) null 'below threshold'
assert equal ([[id content url]; [1 a-b-c u] [2 a-b-d u]] | todo find a-b) null 'tie'
assert equal ([] | todo find anything) null 'no candidates'

# ——— live reads ——————————————————————————————————————————————————————————————

assert ('Inbox' in (todo projects | get name)) 'projects'
assert ((todo labels | length) > 0) 'labels'
let open = todo list --project nu-fluency
assert ('nu-over-bash-hooks' in $open.content) 'list by project'
assert equal ($open | get project | uniq) [nu-fluency] 'project column from the flag'
assert equal (todo view nu-over-bash-hooks | get project) nu-fluency 'view resolves the project name'
assert ((todo task list --project nu-fluency --json | get results | length) > 0) 'passthrough parses json'
assert equal (todo find nu-over-bash-hooks --project nu-fluency | get score) 1.0 'find against the live project'

# ——— live writes (opt-in) ————————————————————————————————————————————————————

if ($env.WARRIOR_TASK_WRITE? | is-not-empty) {
  let t = todo add warrior-task-smoke --description 'delete me'
  assert equal $t.content warrior-task-smoke 'add'
  assert equal (todo edit $t.id --description updated | get description) updated 'update'
  todo done $t.id
  assert ('warrior-task-smoke' in (todo list --completed --since ((date now) - 1day) | get content)) 'done'
  todo reopen $t.id
  todo rm $t.id
  assert ('warrior-task-smoke' not-in (todo list --project Inbox | get content)) 'rm'
}
print 'todo: ok'
