# `todo`: offline matcher, live reads, and opt-in live writes (`TODO_TEST_WRITE=1`): `test todo/tests/suites`.
use ../mod.nu *

def "test find matcher offline" []: nothing -> nothing {
  let rows = [[id content url]; [1 hooks-placement u1] [2 nu-over-bash-hooks u2] [3 generator-migration u3]]
  assert equal ($rows | todo find hooks-placement | select content score) {content: hooks-placement score: 1.0} 'exact match'
  assert equal ($rows | todo find docs/hooks-placement-abort | get content) hooks-placement 'token overlap'
  assert equal ($rows | todo find trust-generator-v3) null 'below threshold'
  assert equal ([[id content url]; [1 a-b-c u] [2 a-b-d u]] | todo find a-b) null 'tie'
  assert equal ([] | todo find anything) null 'no candidates'
}

def "test live reads" []: nothing -> nothing {
  if (which td | is-empty) { skip 'td is not installed' }
  assert ('Inbox' in (todo projects | get name)) 'projects'
  assert ((todo labels | length) > 0) 'labels'
  let open = todo list --project nu-fluency
  assert ('nu-over-bash-hooks' in $open.content) 'list by project'
  assert equal ($open | get project | uniq) [nu-fluency] 'project column from the flag'
  assert equal (todo view nu-over-bash-hooks | get project) nu-fluency 'view resolves the project name'
  assert ((todo task list --project nu-fluency --json | get results | length) > 0) 'passthrough parses json'
  assert equal (todo find nu-over-bash-hooks --project nu-fluency | get score) 1.0 'find against the live project'
}

def "test live writes" []: nothing -> nothing {
  if ($env.TODO_TEST_WRITE? | is-empty) { skip 'set TODO_TEST_WRITE=1 to run the write path against Todoist' }
  let t = todo add todo-test-smoke --description 'delete me'
  assert equal $t.content todo-test-smoke 'add'
  assert equal (todo edit $t.id --description updated | get description) updated 'edit'
  todo done $t.id
  assert ('todo-test-smoke' in (todo list --completed --since ((date now) - 1day) | get content)) 'done'
  todo reopen $t.id
  todo rm $t.id
  assert ('todo-test-smoke' not-in (todo list --project Inbox | get content)) 'rm'
}
