# `alarm` and `alarm/local` against the session store: `test _tests/suites/alarm.nu`.
#
# Alarms live in the in-memory `kv` store and in background jobs of the test child; `after each` unsets them.
# Expiry is exercised with one-second alarms; what an expired alarm prints is read from a sandboxed child.
use alarm
use alarm/local
use ../mod.nu *

# Alarms outlive a test under `--isolation suite`: forget them all.
def "after each" []: nothing -> nothing {
  for name in (alarm list | get key) { alarm unset $name }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Wait until the alarm named `name` is gone (it expired and forgot itself), at most `timeout`.
def wait-gone [name: string, --timeout: duration = 5sec]: nothing -> bool {
  let until: datetime = (date now) + $timeout
  while (alarm show $name) != null and (date now) < $until { sleep 100ms }
  (alarm show $name) == null
}

# Run alarm code in a sandboxed child and return what it printed.
def printed [code: string]: nothing -> string {
  with-sandbox {|ctx|
    let res: record = sandboxed $ctx $code --prelude 'use alarm; use alarm/local'
    if $res.exit_code != 0 { error make --unspanned {msg: $"child failed: ($res.stderr | str trim)"} }
    $res.stdout
  }
}

# ——— set, list, show, unset ———————————————————————————————————————————————————

def "test set returns the stored record" []: nothing -> nothing {
  let item: record = alarm set t-one 1hr --silent
  assert equal ($item | columns) [id description expires_at on_expires] 'the stored record'
  assert equal $item.description 'alarm::t-one' 'the job is named after the alarm'
  assert equal $item.on_expires null 'no callback'
  assert equal (alarm show t-one) $item 'show returns the stored record'
}

def "test list rows use key and description" []: nothing -> nothing {
  let item: record = alarm set t-one 1hr --silent
  let rows: table = alarm list
  assert equal ($rows | columns) [key id description expires_at on_expires] 'the same names as set and show (A1)'
  assert equal ($rows | get key) [t-one] 'listed by name'
  assert equal ($rows | first | reject key) $item 'the rest of the row is the stored record'
}

def "test list filters names by regex" []: nothing -> nothing {
  alarm set work-a 1hr --silent | ignore
  alarm set work-b 1hr --silent | ignore
  alarm set home 1hr --silent | ignore
  assert equal (alarm list '^work' | get key | sort) [work-a work-b] 'only matching names'
  assert equal (alarm list zzz) [] 'no match is an empty table'
}

def "test bare alarm lists and alarm with a name shows" []: nothing -> nothing {
  let item: record = alarm set t-one 1hr --silent
  assert equal (alarm | get key) [t-one] 'bare `alarm` lists'
  assert equal (alarm t-one) $item '`alarm <name>` shows'
  assert equal (alarm nope) null 'an unknown name shows nothing'
}

def "test show of an unknown name is null unless errors are asked for" []: nothing -> nothing {
  assert equal (alarm show nope) null 'null by default'
  let err: record = try { alarm show nope --errors; {} } catch {|e| $e }
  assert equal $err.msg "no alarm named 'nope'" '--errors raises with the name'
  assert equal $err.details?.code? alarm::show::not_found 'the code'
}

def "test a name can only be set once" []: nothing -> nothing {
  alarm set t-one 1hr --silent | ignore
  let err: record = try { alarm set t-one 5min --silent; {} } catch {|e| $e }
  assert equal $err.msg "'t-one' is already set" 'the duplicate is refused'
  assert equal $err.details?.code? alarm::set::conflict 'the code'
}

def "test unset kills the job and forgets the alarm" []: nothing -> nothing {
  let item: record = alarm set t-one 1hr --silent
  assert ((job list).id has $item.id) 'the job is running'
  alarm unset t-one
  assert equal (alarm list) [] 'forgotten'
  assert not ((job list).id has $item.id) 'and its job is killed'
}

def "test unset of an unknown name does nothing" []: nothing -> nothing {
  alarm set keep 1hr --silent | ignore
  alarm unset nope
  assert equal (alarm list | get key) [keep] 'other alarms are untouched'
}

def "test the callback is kept as source" []: nothing -> nothing {
  alarm set t-then 1hr --silent --then {|| 42 } | ignore
  assert equal (alarm show t-then | get on_expires) '{|| 42 }' 'kv cannot hold a closure, so its text is shown'
}

# ——— when —————————————————————————————————————————————————————————————————————

def "test when accepts a datetime as is" []: nothing -> nothing {
  let at: datetime = (date now) + 2hr
  assert equal (alarm set t-at $at --silent | get expires_at) $at 'a datetime is used as is'
}

def "test when accepts a duration from now" []: nothing -> nothing {
  let before: datetime = date now
  let at: datetime = alarm set t-in 2hr --silent | get expires_at
  assert (($at - ($before + 2hr) | math abs) < 5sec) $"expires two hours from now, got ($at)"
}

def "test when accepts a human string" []: nothing -> nothing {
  let at: datetime = alarm set t-human 'in 3 hours' --silent | get expires_at
  assert (($at - ((date now) + 3hr) | math abs) < 1min) $"a human string is parsed, got ($at)"
}

def "test when refuses an unparsable string" []: nothing -> nothing {
  assert error { alarm set t-bad 'not a time' --silent } 'an unparsable string is an error'
  assert error { alarm set t-bad 5 --silent } 'so is a bare number'
  assert equal (alarm list) [] 'nothing is set'
}

# ——— expiry ———————————————————————————————————————————————————————————————————

def "test a fired silent alarm forgets itself" []: nothing -> nothing {
  alarm set t-fire 1sec --silent | ignore
  assert (wait-gone t-fire) 'the job dropped its own row (A2)'
}

def "test a fired alarm frees its name" []: nothing -> nothing {
  alarm set t-fire 1sec --silent | ignore
  assert (wait-gone t-fire) 'expired'
  assert equal (alarm set t-fire 1hr --silent | get description) 'alarm::t-fire' 'the name can be set again'
}

def "test then runs on expiry" []: nothing -> nothing {
  with-sandbox {|ctx|
    let f: path = $ctx.code | path join then.txt
    alarm set t-cb 1sec --silent --then {|| 'ran' | save $f } | ignore
    assert (wait-gone t-cb) 'expired'
    assert equal (open $f) ran 'the callback ran'
  }
}

def "test notify receives the text on expiry" []: nothing -> nothing {
  with-sandbox {|ctx|
    let f: path = $ctx.code | path join notify.txt
    let at: datetime = alarm set t-note 1sec --notify {|text| $text | save $f } | get expires_at
    assert (wait-gone t-note) 'the alarm forgets itself after notifying'
    assert equal (open $f) $"alarm\('t-note', time=($at | format date %T))" 'the alarm text'
  }
}

def "test silent skips notify" []: nothing -> nothing {
  with-sandbox {|ctx|
    let f: path = $ctx.code | path join notify.txt
    alarm set t-quiet 1sec --silent --notify {|text| $text | save $f } | ignore
    assert (wait-gone t-quiet) 'expired'
    assert not ($f | path exists) 'no notification'
  }
}

def "test a failing notify still forgets the alarm" []: nothing -> nothing {
  alarm set t-bad 1sec --notify {|text| error make --unspanned {msg: boom} } | ignore
  assert (wait-gone t-bad) 'the row is dropped anyway'
}

def "test a failing callback still notifies" []: nothing -> nothing {
  with-sandbox {|ctx|
    let f: path = $ctx.code | path join notify.txt
    alarm set t-bad 1sec --then {|| error make --unspanned {msg: boom} } --notify {|text| 'notified' | save $f } | ignore
    assert (wait-gone t-bad) 'expired'
    assert equal (open $f) notified 'notified after the failed callback'
  }
}

def "test the default notification prints the text and the callback output" []: nothing -> nothing {
  let out: string = printed 'alarm set t-print 1sec --then {|| "cb-output" } | ignore; sleep 2500ms'
  assert ($out has 'cb-output') $"the callback output is printed: ($out)"
  assert ($out has "alarm('t-print', time=") $"the alarm text is printed: ($out)"
}

def "test silent prints nothing" []: nothing -> nothing {
  let out: string = printed 'alarm set t-print 1sec --silent --then {|| "cb-output" } | ignore; sleep 2500ms'
  assert equal ($out | str trim) '' 'neither the callback output nor the text'
}

# ——— alarm/local ——————————————————————————————————————————————————————————————

def "test local exports the alarm commands" []: nothing -> nothing {
  let names: list<string> = scope commands | where name =~ '^local( |$)' | get name | sort
  assert equal $names [local 'local list' 'local set' 'local show' 'local unset'] 'main, set and the re-exported commands'
  let flags: list<string> = scope commands | where name == 'local set' | get $.0.signatures | values | first
    | where parameter_type in [switch named] | get parameter_name
  assert ('notify' not-in $flags) 'the notifier is fixed to the dialog'
}

def "test local set delegates to alarm" []: nothing -> nothing {
  let item: record = local set t-local 1hr --silent --then {|| 1 }
  assert equal ($item | select description on_expires) {description: 'alarm::t-local' on_expires: '{|| 1 }'} 'the stored record'
  assert equal (alarm show t-local) $item 'one shared store'
  assert equal (local | get key) [t-local] 'bare `local` lists'
  assert equal (local t-local) $item '`local <name>` shows'
  local unset t-local
  assert equal (local list) [] 'unset through local'
}

def "test local silent alarm fires and forgets itself" []: nothing -> nothing {
  with-sandbox {|ctx|
    let f: path = $ctx.code | path join then.txt
    local set t-local 1sec --silent --then {|| 'ran' | save $f } | ignore
    assert (wait-gone t-local) 'forgotten after expiry'
    assert equal (open $f) ran 'the callback ran'
  }
}

def "test local dialog falls back to printing without a terminal" []: nothing -> nothing {
  # On a terminal `tui run` would open the dialog and wait for a key, so only run where it cannot.
  if (is-terminal --stdin) { skip 'stdin is a terminal: the dialog would open and wait' }
  let out: string = printed 'local set t-local 1sec | ignore; sleep 2500ms; print (alarm list | length)'
  assert ($out has "alarm('t-local', time=") $"the text is printed: ($out)"
  assert equal ($out | lines | last) '0' 'and the alarm is forgotten'
}

def "test local dialog calls match the tui commands" []: nothing -> nothing {
  let cmds: table = scope commands | where name in ['tui label' 'tui button' 'tui run']
  if ($cmds | length) < 3 { skip 'the tui commands are not available' }
  let params: record = $cmds
    | each {|c| {($c.name): ($c.signatures | values | first | get parameter_name | compact)} }
    | into record
  assert ('status' in $params.'tui label') 'tui label --status'
  assert ('hook' in $params.'tui button') 'tui button takes a hook closure'
  assert ('dialog' in $params.'tui run') 'tui run --dialog'
  assert ('size' in $params.'tui run') 'tui run --size'
}
