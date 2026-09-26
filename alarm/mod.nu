# Named alarms that run a callback after a delay or at a given time.

# nu-lint cannot parse the `job spawn` closure below, so its unused-symbol rules misfire here.
# nu-lint-ignore-file: unused_parameter, unused_variable

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv get" "kv set" "kv drop" "kv list" ]

# ——— constants ————————————————————————————————————————————————————————————————

const EMPTY: list<nothing> = []

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-alarm = kv set --table=alarms
alias get-alarm = kv get --table=alarms
alias drop-alarm = kv drop --table=alarms
alias list-alarms = kv list --table=alarms

# ——— definitions —————————————————————————————————————————————————————————————

# Set an alarm.
@category productivity
export def set [
  name: string@$EMPTY # Descriptor for this alarm
  when: oneof<duration, datetime, string>@_suggest-when # When the timer will expire
  --then (-t): closure # Closure to run once the timer expires
  --silent (-s) # Disable default alarm expiration behavior (`clear -k` + print message)
]: nothing -> record {
  if (get-alarm $name) != null { error make $'an alarm named ($name) is already set' }
  let now = date now
  let desc: string = $"alarm::($name)"
  let time: datetime = match ($when | describe) {
    duration => $when
    datetime => { $when | $in - $now }
    string => { $when | date from-human | $in - $now }
    _ => { error make $'received invalid type for `when` argument' }
  } | $in + $now
  plugin use --plugin-config=$nu.plugin-path highlight
  let text: string = $"alarm\('($name)', time='($time | format date %T)')" | highlight Python --theme=Nord
  let item: record = job spawn --description=$desc {||
    while (date now) < $time { sleep 1sec }
    if not $silent { clear --keep-scrollback; print $text }
    if $then != null { try { print (do --env --capture-errors $then) } catch { print --stderr $in.rendered? } }
    drop-alarm $name
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

# List the set alarms.
@category productivity
export def list [
  regex: string = .+ # Regex to filter alarm names by
]: nothing -> table { list-alarms | where key =~ $regex | flatten --all | rename --column={key: name description: desc} }

# Show information about an alarm, if it exists.
@category productivity
export def show [
  name: string@_alarms
  # Name of the alarm to show information about
  --errors (-e)
  # Throw an error instead of returning `null` if the alarm is not found
]: nothing -> oneof<nothing, record> {
  get-alarm $name | match ($in | describe) {
    nothing if $errors => (error make --unspanned $"could not find alarm with name: '($name)'")
    nothing => null
    _ => $in
  }
}

# Set an alarm to print a message to the terminal.
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
