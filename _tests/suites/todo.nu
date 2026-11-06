# `todo` against a `td` stub, plus opt-in live reads (`TODO_TEST_LIVE=1`) and writes (`TODO_TEST_WRITE=1`) against
# the real Todoist account, which need the real home directory: `TODO_TEST_LIVE=1 test _tests/suites/todo.nu --no-sandbox`.
#
# The stub (a nu script first on PATH) appends each call's arguments to `$env.TD_LOG` as a JSON list, and answers
# `td <a> <b> ...` with `$env.TD_DATA/<a>-<b>.json` (default `{"results":[]}`), or fails with the code in
# `<a>-<b>.exit` and the text in `<a>-<b>.err`.
use todo
use ../mod.nu *

def --env "before each" []: nothing -> record<dir: path, log: path, data: path> {
  let dir: path = mktemp --directory --suffix=-todo
  let bin: path = $dir | path join bin
  let data: path = $dir | path join data
  mkdir $bin $data
  stub-td ($bin | path join td)
  $env.TD_LOG = $dir | path join td.log
  $env.TD_DATA = $data
  $env.PATH = $env.PATH | prepend $bin
  {dir: $dir log: $env.TD_LOG data: $data}
}
def "after each" []: record -> nothing { rm --recursive --force $in.dir }

# ——— helpers ——————————————————————————————————————————————————————————————————

def stub-td [path: path]: nothing -> nothing {
  let program: string = r#'
def --wrapped main [...args: string] {
  $"($args | to json --raw)(char nl)" | save --append $env.TD_LOG
  let key: string = $args | first 2 | str join '-'
  let base: path = $env.TD_DATA | path join $key
  if ($"($base).exit" | path exists) {
    print --stderr --no-newline (open --raw $"($base).err")
    exit (open --raw $"($base).exit" | str trim | into int)
  }
  if ($"($base).json" | path exists) { open --raw $"($base).json" } else { '{"results":[]}' } | print --no-newline
}
'#
  $"#!($nu.current-exe) --no-config-file(char nl)($program)" | save $path
  ^chmod +x $path
}

# Every `td` call so far, as argument lists.
def calls [t: record]: nothing -> list<list<string>> {
  if ($t.log | path exists) { open --raw $t.log | lines | each { from json } } else { [] }
}

# Answer `td <a> <b>` with this JSON value.
def respond [t: record, key: string, value: any]: nothing -> nothing {
  $value | to json | save --force ($t.data | path join $"($key).json")
}

# Make `td <a> <b>` fail with this exit code and stderr text.
def fail [t: record, key: string, code: int, err: string]: nothing -> nothing {
  $code | save --force ($t.data | path join $"($key).exit")
  $err | save --force ($t.data | path join $"($key).err")
}

# A task as `td --json` prints it.
def task [id: string, content: string, --project: string = p1, --parent: string, --due: string, --priority: int = 1, --labels: list<string> = []]: nothing -> record {
  {
    id: $id content: $content description: '' priority: $priority
    due: (if $due == null { null } else { {date: $due string: $due isRecurring: false} })
    projectId: $project parentId: $parent labels: $labels url: $"https://app.todoist.com/app/task/($id)"
  }
}

const PROJECTS: record = {results: [
  {id: p1 name: Inbox url: 'https://app.todoist.com/app/project/p1'}
  {id: p2 name: work url: 'https://app.todoist.com/app/project/p2'}
]}

# ——— find (offline) ———————————————————————————————————————————————————————————

def "test find matcher offline" []: nothing -> nothing {
  let rows = [[id content url]; [1 hooks-placement u1] [2 nu-over-bash-hooks u2] [3 generator-migration u3]]
  assert equal ($rows | todo find hooks-placement | select content score) {content: hooks-placement score: 1.0} 'exact match'
  assert equal ($rows | todo find docs/hooks-placement-abort | get content) hooks-placement 'token overlap'
  assert equal ($rows | todo find trust-generator-v3) null 'below threshold'
  assert equal ([[id content url]; [1 a-b-c u] [2 a-b-d u]] | todo find a-b) null 'tie'
  assert equal ([] | todo find anything) null 'no candidates'
}

def "test find returns id content score and url" []: nothing -> nothing {
  let rows = [[id content url extra]; [7 fix-login u7 x]]
  assert equal ($rows | todo find fix-login) {id: 7 content: fix-login score: 1.0 url: u7} 'the selected columns'
  assert equal ([[id content]; [7 fix-login]] | todo find fix-login | get url) null 'a missing url is null'
}

def "test find ignores case and separators in the overlap" []: nothing -> nothing {
  let rows = [[id content url]; [1 Hooks-Placement u]]
  assert equal ($rows | todo find hooks.placement | get score) 1.0 'same token set scores one'
  assert equal ($rows | todo find feat/hooks@placement | get content) Hooks-Placement 'slash and at split too'
}

def "test find threshold is configurable" []: nothing -> nothing {
  let rows = [[id content url]; [1 alpha-beta-gamma-delta u]]
  assert equal ($rows | todo find alpha-zeta) null 'one of five tokens is below the default 0.5'
  assert equal ($rows | todo find alpha-zeta --threshold 0.2 | get score) 0.2 'a lower threshold accepts it'
}

def "test find picks the best of several matches" []: nothing -> nothing {
  let rows = [[id content url]; [1 hooks-placement u1] [2 hooks-placement-abort-x u2]]
  assert equal ($rows | todo find hooks-placement-abort | get id) 2 'three of four tokens beats two of three'
}

# ——— find (through td) ————————————————————————————————————————————————————————

def "test find with a project lists its open tasks" []: record -> nothing {
  let t = $in
  respond $t task-list {results: [(task 1 hooks-placement)]}
  assert equal (todo find docs/hooks-placement-abort --project work | get id) '1' 'matched against td'
  assert equal (calls $t) [[task list --all --json --project work]] 'one task list call for the project'
}

def "test find without a project outside a repository raises" []: record -> nothing {
  let t = $in
  cd $t.dir
  let msg: string = try { todo find anything; 'no error' } catch {|e| $e.msg }
  assert equal $msg 'not inside a repository: pass `--project`' 'the hint names the flag'
}

def "test find without a project uses the repository name" []: record -> nothing {
  let t = $in
  if (which git | is-empty) { skip 'git is not installed' }
  let repo: path = $t.dir | path join my-repo
  ^git init -q $repo
  cd $repo
  respond $t task-list {results: [(task 1 hooks-placement)]}
  assert equal (todo find hooks-placement | get id) '1' 'matched in the repository project'
  assert equal (calls $t | first | last 2) [--project my-repo] 'the project is the basename of the repository root'
}

# ——— list —————————————————————————————————————————————————————————————————————

def "test list sends no options by default" []: record -> nothing {
  let t = $in
  todo list | ignore
  assert equal (calls $t) [[task list --all --json]] 'only the json listing'
}

def "test list maps its flags to td options" []: record -> nothing {
  let t = $in
  todo list --project work --label [a b] --parent t9 --filter 'today' | ignore
  assert equal (calls $t) [[task list --all --json --project work --parent t9 --filter today --label 'a,b']] 'labels are joined with commas'
}

def "test list hydrates rows with the project flag" []: record -> nothing {
  let t = $in
  respond $t task-list {results: [(task 1 one --due 2026-11-09 --priority 4 --labels [x]) (task 2 two --parent 1)]}
  let rows = todo list --project work
  assert equal ($rows | columns) [id content description labels project parent due priority url] 'the row shape'
  assert equal ($rows | get project) [work work] 'the flag names the project of every row'
  assert equal ($rows | get priority) [1 4] 'app priorities: api 4 is p1'
  assert equal ($rows.0?.due | format date %F) '2026-11-09' 'due is a datetime'
  assert equal $rows.1?.due null 'no due date is null'
  assert equal ($rows | get labels) [[x] []] 'labels'
  assert equal ($rows | get parent) [null '1'] 'parent ids'
  assert equal (calls $t | length) 1 'no project lookup'
}

def "test list resolves project names with one lookup" []: record -> nothing {
  let t = $in
  respond $t task-list {results: [(task 1 one --project p2) (task 2 two --project p1) (task 3 three --project zz)]}
  respond $t project-list $PROJECTS
  assert equal (todo list | get project) [work Inbox null] 'names from td project list; unknown ids are null'
  assert equal (calls $t | each { first 2 }) [[task list] [project list]] 'one project list call'
}

def "test list of nothing does not look up projects" []: record -> nothing {
  let t = $in
  assert equal (todo list) [] 'empty'
  assert equal (calls $t | length) 1 'no project lookup for no rows'
}

def "test list completed uses td completed list" []: record -> nothing {
  let t = $in
  respond $t completed-list {results: [(task 1 done-one)]}
  let since: datetime = 2026-11-01T10:00:00+00:00
  assert equal (todo list --completed --project work --since $since | get content) [done-one] 'completed rows'
  assert equal (calls $t) [[completed list --all --json --project work --since '2026-11-01']] 'since is a date'
}

def "test list completed refuses open task filters" []: record -> nothing {
  let t = $in
  let msg: string = try { todo list --completed --label [a] --filter today; 'no error' } catch {|e| $e.msg }
  assert equal $msg '`--completed` cannot be combined with `--label`, `--filter`' 'names the ignored flags (D6)'
  assert equal (calls $t) [] 'td is not called'
}

def "test a failing json read raises with td output" []: record -> nothing {
  let t = $in
  fail $t task-list 1 '{"error":"INVALID_PRIORITY"}'
  let err: record = try { todo list; {} } catch {|e| {msg: $e.msg help: ($e.details?.help? | default '')} }
  assert equal $err.msg '`td` exited with code 1' 'the exit code'
  assert ($err.help has INVALID_PRIORITY) $"td's stderr is the help: ($err.help)"
}

def "test stderr does not corrupt a successful json read" []: record -> nothing {
  let t = $in
  let td: path = $t.dir | path join bin td
  let program: string = open --raw $td
    | str replace 'def --wrapped main [...args: string] {' "def --wrapped main [...args: string] {\n  print --stderr 'warning: update available'"
  $program | save --force $td
  respond $t task-list {results: [(task 1 one)]}
  assert equal (todo list | get content) [one] 'only stdout is parsed'
}

# ——— view, add, edit ——————————————————————————————————————————————————————————

def "test view returns one hydrated row" []: record -> nothing {
  let t = $in
  respond $t task-view (task t1 one --project p2)
  respond $t project-list $PROJECTS
  let row = todo view t1
  assert equal ($row | select id content project) {id: t1 content: one project: work} 'a single row with the project name'
  assert equal (calls $t | first) [task view t1 --json] 'td task view'
}

def "test add maps its flags to td options" []: record -> nothing {
  let t = $in
  respond $t task-add (task t1 'buy milk')
  let row = todo add 'buy milk' --project work --description 'two litres' --labels [a b] --parent t0 --due 2026-11-09T08:00:00+00:00 --priority 1
  assert equal (calls $t) [[task add 'buy milk' --json --project work --description 'two litres' --labels 'a,b' --parent t0 --due '2026-11-09' --priority p1]] 'the td call'
  assert equal ($row | select id project) {id: t1 project: work} 'returns the created row'
}

def "test add passes a due string through" []: record -> nothing {
  let t = $in
  respond $t task-add (task t1 x)
  respond $t project-list $PROJECTS
  todo add x --due 'every monday' | ignore
  assert equal (calls $t | first) [task add x --json --due 'every monday'] 'the Todoist due string'
}

def "test edit maps its flags to td options" []: record -> nothing {
  let t = $in
  respond $t task-update (task t1 renamed)
  respond $t project-list $PROJECTS
  let row = todo edit t1 --content renamed --labels [x] --priority 4 --no-due
  assert equal (calls $t | first) [task update t1 --json --content renamed --labels x --priority p4 --no-due] 'kebab-case --no-due (D1)'
  assert equal $row.content renamed 'returns the updated row'
}

# ——— projects, labels, passthrough ————————————————————————————————————————————

def "test projects and labels select their columns" []: record -> nothing {
  let t = $in
  respond $t project-list {results: [{id: p1 name: Inbox url: u color: red}]}
  respond $t label-list {results: [{id: l1 name: urgent color: red}]}
  assert equal (todo projects) [{id: p1 name: Inbox url: u}] 'id, name and url'
  assert equal (todo labels) [{id: l1 name: urgent}] 'id and name'
}

def "test json passthrough hydrates task rows" []: record -> nothing {
  let t = $in
  respond $t task-list {results: [(task 1 one --due 2026-11-09)]}
  respond $t project-list $PROJECTS
  let rows = todo task list --project Inbox --json
  assert equal ($rows | get project) [Inbox] 'hydrated'
  assert equal (calls $t | first) [task list --project Inbox --json] 'arguments in order, --json appended'
}

def "test json passthrough leaves other rows alone" []: record -> nothing {
  let t = $in
  respond $t project-list $PROJECTS
  assert equal (todo project list --json) $PROJECTS.results 'not task-shaped'
}

def "test long json passthrough keeps every column" []: record -> nothing {
  let t = $in
  respond $t task-list {results: [(task 1 one --due 2026-11-09 | insert extra x) ({id: 2 content: two priority: 1 url: u})]}
  respond $t project-list $PROJECTS
  let rows = todo task list --json --long
  assert (($rows | first) has extra) 'extra columns are kept'
  assert equal $rows.0?.due.date '2026-11-09' 'due stays a record'
  assert equal ($rows | get parent) [null null] 'rows without parentId are tolerated (D5)'
}

def "test plain passthrough runs td directly" []: record -> nothing {
  let t = $in
  respond $t task-list {results: []}
  let res = todo task list --project work | complete
  assert equal ($res.stdout | from json) {results: []} 'td output untouched'
  assert equal (calls $t | first) [task list --project work] 'no --json added'
}

# ——— writes (through elevate with-auth) ———————————————————————————————————————

def "test done reopen rm and browse loop over their references" []: record -> nothing {
  let t = $in
  todo done t1 t2
  todo reopen t1
  todo rm t1 t2
  todo browse t3
  let expected = [
    [task complete t1] [task complete t2] [task uncomplete t1]
    [task delete t1 --yes] [task delete t2 --yes] [task browse t3]
  ]
  assert equal (calls $t) $expected 'one td call per reference'
}

def "test an auth failure raises outside an interactive session" []: record -> nothing {
  let t = $in
  fail $t task-complete 1 'Not authenticated. Run `td auth login`'
  assert error { todo done t1 } 'no login prompt without a terminal'
  assert equal (calls $t | length) 1 'no retry'
}

# ——— live (opt-in) ————————————————————————————————————————————————————————————

# The real `td`: PATH without the stub.
def --env unstub [t: record]: nothing -> nothing {
  $env.PATH = $env.PATH | where {|p| not ($p | str starts-with $t.dir) }
}

def "test live reads" []: record -> nothing {
  let t = $in
  if ($env.TODO_TEST_LIVE? | is-empty) { skip 'set TODO_TEST_LIVE=1 (and run with --no-sandbox) to read the live Todoist account' }
  unstub $t
  if (which td | is-empty) { skip 'td is not installed' }
  assert ('Inbox' in (todo projects | get name)) 'projects'
  assert ((todo labels | length) > 0) 'labels'
  let open = todo list --project nu-fluency
  assert ('nu-over-bash-hooks' in $open.content) 'list by project'
  assert equal ($open | get project | uniq) [nu-fluency] 'project column from the flag'
  assert equal (todo view nu-over-bash-hooks | get project) nu-fluency 'view resolves the project name'
  assert ((todo task list --project nu-fluency --json | get content) has nu-over-bash-hooks) 'passthrough hydrates task json'
  assert ((todo --json project list | get name) has Inbox) 'passthrough parses other json untouched'
  assert equal (todo find nu-over-bash-hooks --project nu-fluency | get score) 1.0 'find against the live project'
}

def "test live writes" []: record -> nothing {
  let ctx = $in
  if ($env.TODO_TEST_WRITE? | is-empty) { skip 'set TODO_TEST_WRITE=1 (and run with --no-sandbox) to run the write path against Todoist' }
  unstub $ctx
  if (which td | is-empty) { skip 'td is not installed' }
  let t = todo add todo-test-smoke --description 'delete me'
  assert equal $t.content todo-test-smoke 'add'
  assert equal (todo edit $t.id --description updated | get description) updated 'edit'
  todo done $t.id
  assert ('todo-test-smoke' in (todo list --completed --since ((date now) - 1day) | get content)) 'done'
  todo reopen $t.id
  todo rm $t.id
  assert ('todo-test-smoke' not-in (todo list --project Inbox | get content)) 'rm'
}
