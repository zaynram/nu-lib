# `alarm` against the session store: `test alarm/tests/suites`. Every test unsets what it sets.
use ../mod.nu *

def "test set, list, show and unset" []: nothing -> nothing {
  let item: record = alarm set t-one 1hr --silent
  assert equal ($item | columns) [id description expires_at on_expires] 'the stored record'
  assert equal $item.description 'alarm::t-one' 'the job is named after the alarm'
  assert equal $item.on_expires null 'no callback'
  assert equal (alarm list | get key) [t-one] 'listed by name'
  assert equal (alarm | get key) [t-one] 'bare `alarm` lists'
  assert equal (alarm t-one) $item '`alarm <name>` shows'
  assert equal (alarm show t-one) $item 'show returns the stored record'
  assert equal (alarm show nope) null 'an unknown name shows nothing'
  assert error { alarm show nope --errors } 'unless asked to throw'
  assert error { alarm set t-one 5min --silent } 'a name is set once'
  assert ((job list).id has $item.id) 'the job is running'
  alarm unset t-one
  assert equal (alarm list) [] 'forgotten'
  assert not ((job list).id has $item.id) 'and its job is killed'
  alarm unset t-one
}

def "test the callback is kept as source" []: nothing -> nothing {
  let item: record = alarm set t-then 1hr --silent --then {|| 42 }
  assert equal (alarm show t-then | get on_expires) '{|| 42 }' 'kv cannot hold a closure, so its text is shown'
  alarm unset t-then
}

def "test when accepts a datetime or a human string" []: nothing -> nothing {
  let at: datetime = (date now) + 2hr
  assert equal (alarm set t-at $at --silent | get expires_at) $at 'a datetime is used as is'
  assert ((alarm set t-human 'in 3 hours' --silent | get expires_at) > $at) 'a human string is parsed'
  assert error { alarm set t-bad 5 --silent } 'anything else is refused'
  alarm unset t-at
  alarm unset t-human
}

def "test a fired alarm forgets itself" []: nothing -> nothing {
  alarm set t-fire 1sec --silent | ignore
  sleep 2500ms
  assert equal (alarm list t-fire) [] 'the job dropped its own row'
}
