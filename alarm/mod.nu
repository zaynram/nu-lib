# ——— environment —————————————————————————————————————————————————————————————

export-env {
  let alarms: table<id: int, name: string, time: datetime, then: oneof<closure, nothing>> = []
  load-env {time: {alarms: $alarms}}
}

# ——— definitions —————————————————————————————————————————————————————————————

# Set an alarm.
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
  let text: string = { # nu-lint-ignore: unused_variable
      prefix: $"(ansi rb)alarm(ansi rst)\("
      name: $"(ansi yb)name(ansi rst)=(ansi c)'($name)'(ansi rst)"
      sep: $"(ansi black_bold),(ansi rst)"
      time: $"(ansi yb)time(ansi rst)=(ansi w)($time | format date %T)(ansi rst)"
      suffix: ")\r"
    } | values | str join

  # topiary: disable
  let id: int = job spawn --description $name { # nu-lint-ignore: nu_parse_error
      sleep $wait
      if not $silent { clear --keep-scrollback | print $text }
      if $then != null { do --env --capture-errors $then | print }
      job id | wrap id | alarm unset --no-kill
    }

  let item: record = {id: $id name: $name time: $time then: $then}
  $env.time.alarms ++= [$item]

  return $item
}

# Unset an alarm.
export def --env unset [
  name?: string@_alarms # Name of the alarm to abort
  --no-kill # Do not attempt to end the job process
]: oneof<nothing, record<id: int>> -> nothing {
  let spec: record = $in
    | default --empty { $name | wrap name }
    | select --ignore-case --optional id name
    | compact

  if ($spec | is-empty) { error make --unspanned 'alarm name or job input is required' }

  let item: record = match $spec {
    {name: $_} => { $env.time.alarms | where name == $_ }
    {id: $_} => { $env.time.alarms | where id == $_ }
  } | first

  if $item == null { return }
  if not $no_kill and (job list).id has $item.id { job kill $item.id }

  $env.time.alarms = $env.time.alarms | where name != $item.name
}

# List the set alarms.
export def "alarm list" [
  regex: string = .+ # Regex to filter alarm names by
]: nothing -> table {
  $env.time.alarms | where name =~ $regex
}

# Set an alarm to print a message to the terminal.
export def --env main [
  name?: string # Name of the alarm to set or check
  --set: oneof<datetime, duration> # Datetime or duration for the alarm to expire
  --unset: string@_alarms # Abort the alarm matching `name`
]: nothing -> oneof<nothing, table> {
  if $set != null {
    alarm set ($name | default $'alarm_($env.time.alarms | length)') $set
  } else if $unset != null {
    alarm unset $unset
  } else {
    alarm list
  }
}

# ——— completions —————————————————————————————————————————————————————————————

def _empty []: nothing -> list { [] }
def _alarms []: nothing -> list { $env | get --optional time.alarms | default [] | get name }
def _suggest-when []: nothing -> list {
  [1min 5min 10min 15min 20min 30min 1hr 1.5hr 2hr] | par-each {|add|
    date now | $in + $add | date humanize | $"'($in)'"
  }
}
