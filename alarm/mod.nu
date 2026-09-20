# Named alarms that run a callback after a delay or at a given time.

# nu-lint cannot parse the `job spawn` closure below, so its unused-symbol rules misfire here.
# nu-lint-ignore-file: unused_parameter, unused_variable

# ——— environment —————————————————————————————————————————————————————————————

export-env {
  let alarms: table<id: int, name: string, time: datetime, then: oneof<closure, nothing>> = []
  load-env {time: {alarms: $alarms}}
}

# ——— definitions —————————————————————————————————————————————————————————————

# Set an alarm.
@category productivity
export def --env set [
  name: string@_empty # Descriptor for this alarm
  when: oneof<duration, datetime, string>@_suggest-when # When the timer will expire
  --then (-t): closure # Closure to run once the timer expires
  --silent (-s) # Disable default alarm expiration behavior (`clear -k` + print message)
]: nothing -> record {
  if $env.time.alarms.name has $name { error make $'an alarm named ($name) is already set' }
  let now: datetime = date now
  let wait: duration = match ($when | describe) {
    duration => $when
    datetime => { $when | $in - $now }
    string => { $when | date from-human | $in - $now }
    _ => { error make $'received invalid type for `when` argument' }
  }
  let time: datetime = $now + $wait

  # topiary: disable
  let text: string = {
      prefix: $"(ansi rb)alarm(ansi rst)\("
      name: $"(ansi yb)name(ansi rst)=(ansi c)'($name)'(ansi rst)"
      sep: $"(ansi black_bold),(ansi rst)"
      time: $"(ansi yb)time(ansi rst)=(ansi w)($time | format date %T)(ansi rst)"
      suffix: ")\r"
    } | values | str join

  let item: record = job spawn --description $name {
    try {
      sleep $wait
      if not $silent { clear --keep-scrollback | print $text }
      if $then != null { do --env --capture-errors $then | print }
    } catch {
      ignore
    } finally {
      unset $name
    }
  } | {id: $in name: $name time: $time then: $then}
  $env.time.alarms ++= [$item]
  return $item
}

# Unset an alarm.
@category productivity
export def --env unset [
  name?: string@_alarms # Name of the alarm to abort
]: oneof<nothing, record<id: int>> -> nothing {
  let id: oneof<nothing, int> = default {} | get $.id!?
  let item: record = $env.time.alarms
    | if $id != null {
      where id == $id
    } else if $name != null {
      where name == $name
    } else {
      error make --unspanned 'no name or id was provided'
    } | first
    | match ($in | describe) { nothing => { return } _ => { } }
  if (job list).id has $item.id { job kill $item.id }
  $env.time.alarms = $env.time.alarms | where id != $item.id
}

# List the set alarms.
@category productivity
export def list [
  regex: string = .+ # Regex to filter alarm names by
]: nothing -> table { $env.time.alarms | where name =~ $regex }

# Set an alarm to print a message to the terminal.
@category productivity
export def --env main [
  name?: string # Name of the alarm to set or check
  --set: oneof<datetime, duration> # Datetime or duration for the alarm to expire
  --unset: string@_alarms # Abort the alarm matching `name`
]: nothing -> oneof<nothing, record, table> {
  if $set != null {
    set ($name | default $'alarm_($env.time.alarms | length)') $set
  } else if $unset != null {
    unset $unset
  } else { list }
}

# ——— completions —————————————————————————————————————————————————————————————

def _empty []: nothing -> list { [] }
def _alarms []: nothing -> list { $env.time?.alarms? | default [] | get name }
def _suggest-when []: nothing -> list {
  let now = date now
  [1min 5min 10min 15min 20min 30min 1hr 1.5hr 2hr] | each {|dur|
    $now + $dur | date humanize | $"'($in)'"
  }
}
