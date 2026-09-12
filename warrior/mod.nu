# nu-lint-ignore-file: custom_log_command

use ../util "into completions"

const DATA = {
  time: ($nu.data-dir | path basename --replace timewarrior/data)
  task: ($nu.data-dir | path basename --replace task)
}

export module time {

  # ——— definitions —————————————————————————————————————————————————————————————

  # Interact with the Timewarrior CLI.
  export def --wrapped main [
    ...rest: string@_timew-raw # Arguments to pass directly to the `timew` interface
  ]: nothing -> nothing { run-external timew ...$rest }

  # Describe an item to record time for via the `timew` CLI.
  @category productivity
  export def desc [
    slug: string
    # Descriptor of the work item's scope
    --tag (-t): string@_time_tags
    # Identifier for the parent scope; defaults to basename of working directory
    --cd (-c): directory
    # Change to this directory before constructing tags
    --rev-parse (-r)
    # Use the repository root of the `pwd` or `--cd` (if given) as the tag
    ...rest: string@_time_tags
    # Arguments to pass to `timew start`; positionals are extra tags by default
  ]: nothing -> nothing {
    if $cd != null and ($cd | path type) == dir { cd $cd }
    match $tag {
      _ if $rev_parse => { timew start (resolve-repo-root | path basename) $slug ...($rest | prepend $tag | compact) }
      null => { timew start (pwd | path basename) $slug ...$rest }
      _ => { timew start $tag $slug ...$rest }
    }
  }

  # Convert a datetime and/or duration value into a `timew` interval.
  @category datetime
  export def span [
    --from: datetime@_common-datetimes # Anchor date for the interval
    --span: duration@_common-durations # Timespan for the interval
    --text (-t) # Return a string instead of a list of arguments
  ]: [
    nothing -> list<string>
    record<from: datetime> -> list<string>
    record<span: duration> -> list<string>
    record<from: oneof<nothing, datetime>, span: oneof<nothing, duration>> -> list<string>
    any -> oneof<string, list<string>>
  ] {
    match ($in | default {} | default $from from | default $span span | compact) {
      {from: $f span: $s} => [from ($f | str-datetime) for ($s | str-duration)]
      {span: $s} if $s < 0sec => [from (date now | $in + $s | str-datetime)]
      {span: $s} => [($s | str-duration) ago]
      {from: $f} => [from ($f | str-datetime)]
      _ => []
    } | if $text { str join (char sp) } else { }
  }

  # Summarize the Timewarrior data with automatic conversion to Nushell types.
  @category productivity
  @category datetime
  export def --wrapped line [
    --from: datetime@_common-datetimes # Anchor bound for interval filtering
    --span: duration@_common-durations # Duration bound for interval filtering
    --then: closure # Process entries before returning the output (custom filtering)
    --last: number = nan # Include this many of the most recent entries
    ...rest: string # Tags or IDs ('@<n>') to pass through for filtering entries
  ]: [
    nothing -> table<id: int, span: duration, tags: oneof<string, list>, start: datetime, end: datetime>
    nothing -> table<id: int, span: duration, tags: oneof<string, list>, start: datetime>
  ] {
    timew export ...({from: $from span: $span} | span) ...$rest out+err>|
    | complete
    | if $in.exit_code != 0 {
      error make --unspanned {
        msg: '`timew export` exited with non-zero exit code'
        code: `common::timewarrior::timeline::external_command_error`
        help: $"code: ($in.exit_code)\n[output]\n($in.stdout)"
      }
    } else { get stdout | from json }
    | if ($last | into int | into bool) { last $last } else { }
    | insert zone {|row| $row.tags | first }
    | update tags { skip 1 | match ($in | length) { 1 => { first } _ => { } } }
    | update start { into datetime | date to-timezone local }
    | upsert end { try { into datetime | date to-timezone local } catch { ignore } }
    | insert span {|row| ($row.end? | default { date now }) - $row.start }
    | if $then != null {
      do --capture-errors $then $in
    } else {
      select --optional id zone span tags start end | compact --empty
    }
  }

  # Show the timeline summary for the current day.
  export alias show = line --span=1day
  # Show the timeline summary for the current week.
  export alias week = line --span=1wk
  # Open the Timewarrior documentation page in a browser.
  export alias docs = start https://timewarrior.net/docs/
  # Continue tracking time for the an entry.
  export alias cont = timew continue
  # Return the tags data as a Nushell table.
  export def tags []: nothing -> table<name: string, count: int> {
    $DATA.time
    | path join tags.data
    | path expand --strict
    | open --raw
    | from json
    | transpose name count
    | flatten count
  }

  # ——— helpers —————————————————————————————————————————————————————————————————

  def str-duration []: duration -> string {
    math abs | format duration min | split words | str join
  }
  def str-datetime []: datetime -> string {
    date to-timezone local | format date %s
  }

  # ——— completions —————————————————————————————————————————————————————————————

  #topiary: disable
  def _timew-raw [context: string]: nothing -> record { # nu-lint-ignore: positional_to_pipeline
    $context
    | str replace --regex '^time\s' 'timew '
    | commandline complete
    | str trim --right
    | where $it not-in [show week day start summary export]
    | into completions {sort: false}
  }
}

export module task {
  use ../repo # nu-lint-ignore: nu_parse_error
  # Add a task with the Taskwarrior (`task`) CLI.
  export def --wrapped add [
    ...rest: string # The task description and additional arguments
    --context (-c): string@_contexts # Swap to this context (prior to adding this task)
    --zone (-z): string@_projects # The project associated with this task
    --wait (-w): datetime # The date to wait before this task becoms pending
    --tags (-t): oneof<list<string>, record<-: list<string>>, record<+: list<string>, -: list<string>>> = {
    } # Tags to add or remove from this task
    --progress (-p): string@_progression # The status for the task (pending|completed|deleted|waiting)
    --raw-args (-R) # Pass the commandline directly to `task` CLI instead of formatting them first
    --priority (-P): string@_priorities # The priority of this task (H|M|L)
    --due-date (-d): datetime # The due date for this task
    --schedule (-s): oneof<datetime, record<start: datetime, end: datetime>> # The scheduled date or timeline this task covers (dates only)
    --repeat (-r): string@_frequencies # Repeat the task with a set frequency
    --until (-u): datetime@_common_dates # The expiration date for this task (used with `--repeat`)
    --complete (-C) # Log the task as already completed instead of adding it
  ]: nothing -> string {
    if $context != null { swap $context | print }
    if $raw_args { $rest } else {
      {
        command: (if $complete { 'log' } else { 'add' })
        project: $zone
        priority: $priority
        tags: $tags
        due: $due_date
        wait: $wait
        schedule: $schedule
        complete: $complete
        status: $progress
        recur: $repeat
        until: $until
      } | mkargs ...$rest
    } | collect {|ls| first | wrap name | insert args { $ls | skip 1 } }
    | if ($in.name | is-empty) and not $raw_args {
      error make --unspanned 'unable to resolve subcommand'
    } else {
      let command: record = $in
      task ...($command | values) out+err>|
      | complete
      | match $in.exit_code {
        0 => { return $in.stdout }
        _ => {
          error make --unspanned {
            msg: $"taskwarrior exited a with non-zero exit code: ($in.exit_code)"
            code: $'warrior::task::($command.name)::non_zero_exit_code'
            help: $"[output]\n($in.stdout)"
          }
        }
      }
    }
  }
  # Swap to a different task context (or clear the current one).
  export def swap [
    context?: string # The context to set (pass 'none' or use `--clear` to unset the current context)
    --clear (-c) # Clear the current task context
  ]: nothing -> string {
    match ($context | describe) {
      string => $context
      nothing if $clear => 'none'
      _ => {
        error make {
          msg: 'no context was provided'
          code: `warrior::task::swap::invalid_context`
          label: {text: context span: (metadata $context).span}
          help: $"context must be a non-empty string when not using `--clear`"
        }
      }
    } | task context $in out+err>|
    | complete
    | match $in.exit_code {
      0 => { return $in.stdout }
      $c => {
        error make --unspanned {
          msg: $'taskwarrior exited with a non-zero exit code: ($c)'
          code: `warrior::task::add::context.non_zero_exit_code`
          help: $"[output]\n($in.stdout)"
          label: {text: context span: (metadata $context).span}
        }
      }
    }
  }
}

# ——— utilities ——————————————————————————————————————————————————————————————

def resolve-repo-root []: nothing -> oneof<error, directory> {
  match (git rev-parse --show-toplevel | complete) {
    {exit_code: 0 stdout: $o} => { $o | str trim | path expand --strict }
    {exit_code: $c stderr: $e} => {
      error make {
        msg: $'git exited with code ($c)'
        code: 'warrior::time::non_zero_exit_code'
        help: $"[stderr]\n($e)"
      }
    }
  }
}

def "str chrono" []: oneof<duration, datetime> -> string {
  match ($in | describe) {
    datetime => { format date %FT%T%:z }
    duration => { $"P($in // 1day)DT(($in mod 1day) / 1hr | math round --precision=1)H" }
  }
}

def mkargs [...args: string]: record<command: string> -> list<string> {
  let vars: record = default {} | compact --empty
  let done: bool = $vars.complete? | into bool --relaxed
  def throw [flag: string requires: string --with: list<string>]: nothing -> error {
    let end: oneof<nothing, string> = if ($with | is-not-empty) { $'with ($with | par-each { $'`--($in)`' } | str join `, `)' }
    error make --unspanned $"`--($flag)` must ($requires)($end)."
  }
  [$vars.command]
  | if $vars has project { append [project:($vars.project)] } else { }
  | if $vars has priority { append [priority:($vars.priority)] } else { }
  | if $vars has status { append [status:($vars.status)] } else { }
  | if $vars has tags { append ($vars.tags | items {|k v| $v | par-each { $k + $in } } | flatten) } else { }
  | if $vars has due and not $done { append [due:($vars.due | str chrono)] } else { }
  | if $vars has recur { append [recur:($vars.recur)] } else { }
  | if $vars has until { append [until:($vars.until | str chrono)] } else { }
  | if $vars has schedule {
    append (
      $vars.schedule | match ($in | describe) {
        datetime if $done => { throw schedule 'be a record' --with=[complete=true] }
        datetime => [scheduled:($in | format date %F)]
        _ => { items {|k v| [$k $v] | format date %F | str join : } }
      }
    )
  } else { }
  | append [-- ...$args]
}

# ——— completions ——————————————————————————————————————————————————————————————

def _time_tags []: nothing -> oneof<list, record> {
  $DATA.time
  | path join tags.data
  | try { path expand --strict | open --raw | from json | columns }
  | default --empty {
    timew tags
    | complete
    | get stdout
    | str replace 'No data found.' ''
    | lines
    | str trim
  } | into completions {
    case_sensitive: false
    completion_algorithm: prefix
    sort: true
  }
}

def _projects []: nothing -> record {
  {
    options: {
      case_sensitive: false
      completion_algorithm: substring
      sort: true
    }
    completions: (
      repo list
      | insert description {|row| $"github:($row.owner)/($row.name)" }
      | select name description
      | rename --column={name: value}
    )
  }
}

def _priorities []: nothing -> record {
  {
    options: {
      case_sensitive: false
      completion_algorithm: prefix
      sort: false
    }
    completions: [
      [value description];
      [H 'High priority; use for active tasks']
      [M 'Medium priority; use for sequencing next tasks']
      [L 'Low priority; use for chores and non-development tasks']
    ]
  }
}

def _progression []: nothing -> record {
  {
    options: {
      case_sensitive: false
      completion_algorithm: prefix
      sort: false
    }
    completions: [
      [value description];
      [pending 'Ready; marks a task as not started but not waiting']
      [completed 'Done; marks a task as finished']
      [deleted 'Removed; marks a task as abandoned and removes it from tracking']
      [waiting 'Queued; marks a task as waiting to start until a certain date']
    ]
  }
}

def _frequencies []: nothing -> record {
  {
    options: {
      case_sensitive: false
      completion_algorithm: fuzzy
      sort: false
    }
    completions: [
      [value description];
      [daily 'Every day']
      [1day 'Every <n=1> days']
      [weekdays 'Every week on Mon, Tue, Wed, Thu, Fri']
      [weekly 'Every week']
      [1wk 'Every <n=1> weeks']
      [biweekly 'Every two weeks']
      [fortnight 'Every two weeks']
      [monthly 'Every month']
      [1mo 'Every <n=1> month']
      [quarterly 'Every three months']
      [1qtr 'Every <n=1> quarters']
      [semiannual 'Every six months']
      [annual 'Every year']
      [yearly 'Every year']
      [1yr 'Every <n=1> years']
      [biannual 'Every two years']
      [biyearly 'Every two years']
    ]
  }
}

def _contexts []: nothing -> record {
  {
    options: {
      case_sensitive: false
      completion_algorithm: fuzzy
      sort: false
    }
    completions: []
  }
}

def _common_dates []: nothing -> record {
  let now = date now
  {
    options: {
      case_sensitive: false
      completion_algorithm: substring
      sort: true
    }
    completions: (1..45 | par-each { $in * 1day | $now + $in | format date %F })
  }
}

def _common-durations [context: string = '' --raw --abs]: [
  nothing -> oneof<list<duration>, record>
] {
  let pos = $abs or $context =~ `--from[\s|=]\.+`
  [1hr 6hr 12hr 1day 3day 5day 1wk 2wk 4wk]
  | if $pos { } else { par-each {|d| [$d ($d * -1)] } | flatten }
  | sort --reverse
  | if $raw { } else { into string | into completions {sort: false} }
}

def _common-datetimes []: [nothing -> record] {
  let now = date now
  _common-durations --raw --abs
  | par-each { $now - $in | format date %FT%T%:z }
  | into completions
}
