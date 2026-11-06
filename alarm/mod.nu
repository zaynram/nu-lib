# Named alarms that run a callback after a delay or at a given time.
#
# Alarms belong to this session: each one is a background job, and its record lives in the in-memory `kv`
# store (table `alarms`), so other shells do not see it and it ends with the session. An expired alarm runs
# its callback, notifies (see `set --notify`; the default prints its text) and forgets itself. This module is
# abstract; `alarm/local` makes a `tui` dialog the default notification.

# nu-lint cannot parse the `job spawn` closure below, so its unused-symbol rules misfire here.
# nu-lint-ignore-file: unused_parameter, unused_variable

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv get" "kv set" "kv drop" "kv list" ]
use error

# ——— constants ————————————————————————————————————————————————————————————————

const EMPTY: list<nothing> = []

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-alarm = kv set --table=alarms
alias get-alarm = kv get --table=alarms
alias drop-alarm = kv drop --table=alarms
alias list-alarms = kv list --table=alarms

# ——— definitions —————————————————————————————————————————————————————————————

# Set an alarm; returns its record `{id description expires_at on_expires}`.
#
# `when` is a delay, a datetime, or a human string such as 'in 2 hours'. On expiry the alarm runs `--then`,
# notifies with its text `alarm('<name>', time=<HH:MM:SS>)`, and then forgets itself (its name is free again).
@category productivity
export def set [
  name: string@$EMPTY # Descriptor for this alarm
  when: oneof<duration, datetime, string>@_suggest-when # When the timer will expire
  --then (-t): closure # Closure to run once the timer expires; its output is printed unless `--silent`
  --silent (-s) # Expire quietly: no notification, and the callback's output is discarded
  --notify (-n): closure # Called with the alarm's text as its argument on expiry; default: print the text
]: nothing -> record {
  if (get-alarm $name) != null {
    error raise $"an alarm named '($name)' is already set" --kind conflict --advice 'unset it first, or choose another name'
  }
  let now = date now
  let desc: string = $"alarm::($name)"
  let time: datetime = match ($when | describe) {
    duration => $when
    datetime => { $when | $in - $now }
    string => { $when | date from-human | $in - $now }
    _ => { error raise $"unsupported type for 'when': ($when | describe)" --kind invalid_argument }
  } | $in + $now
  let text: string = $"alarm\('($name)', time=($time | format date %T))"
  # Not `default`: it would call a closure argument to compute the default.
  let notify: closure = if $notify != null { $notify } else { {|text: string| print $text } }
  let item: record = job spawn --description=$desc {||
    loop {
      let left: duration = $time - (date now)
      if $left <= 0sec { break }
      sleep ([$left 1sec] | math min)
    }
    if $then != null { do --ignore-errors $then | if not $silent { print } }
    if not $silent { try { do $notify $text | ignore } }
    drop-alarm $name | ignore
  } | {id: $in description: $desc expires_at: $time on_expires: (if $then == null { null } else { view source $then })}
  set-alarm --return=value $name $item
}

# Unset an alarm.
@category productivity
export def unset [
  name: string@_alarms # Name of the alarm to abort
]: nothing -> nothing {
  let item: oneof<nothing, record> = get-alarm $name
  if $item == null { return }
  if (job list).id has $item.id { job kill $item.id }
  drop-alarm $name | ignore
}

# List the set alarms: `{key id description expires_at on_expires}` rows, `key` being the alarm's name.
@category productivity
export def list [
  regex: string = .+ # Regex to filter alarm names by
]: nothing -> table { list-alarms | where key =~ $regex | flatten --all }

# Show information about an alarm, if it exists.
@category productivity
export def show [
  name: string@_alarms
  # Name of the alarm to show information about
  --errors (-e)
  # Throw an error instead of returning `null` if the alarm is not found
]: nothing -> oneof<nothing, record> {
  get-alarm $name | match ($in | describe) {
    nothing if $errors => (error raise $"no alarm named '($name)'" --kind not_found)
    nothing => null
    _ => $in
  }
}

# List the alarms, or show one by name.
@category productivity
export def main [
  name?: string # Name of the alarm to set or check
]: nothing -> oneof<nothing, record, table> {
  $name | match ($in | describe) { nothing => (list) string => (show $in) }
}

# ——— completions —————————————————————————————————————————————————————————————

def _alarms []: nothing -> list { list-alarms | get key }

def _suggest-when []: nothing -> list {
  let now = date now
  [1min 5min 10min 15min 20min 30min 1hr 1.5hr 2hr]
  | each { $now + $in | date humanize | $"'($in)'" }
}
