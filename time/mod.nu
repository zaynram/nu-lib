# Time tracking with the Timewarrior CLI: typed intervals, completions and datetime conversion.

use ../util "into completions"

# ——— constants ——————————————————————————————————————————————————————————————

# Database root; `$env.TIMEWARRIORDB` overrides it at runtime.
const DB: path = $nu.data-dir | path basename --replace timewarrior
const COMMANDS: list<string> = [annotate cancel config continue day delete diagnostics export extensions gaps get help join lengthen modify month move report shorten show split start stop summary tag tags track undo untag week]
const HINTS: list<string> = [:day :yesterday :week :lastweek :fortnight :month :lastmonth :quarter :lastquarter :year :lastyear :all :ids :fill :adjust :monday :tuesday :wednesday :thursday :friday :saturday :sunday]
const SPANS: list<duration> = [1hr 6hr 12hr 1day 3day 1wk 2wk 4wk]

# ——— definitions —————————————————————————————————————————————————————————————

# Pass arguments straight to `timew`.
@category productivity
export def --wrapped main [
  ...rest: string@_timew # Arguments for `timew`; completions cover subcommands, tags, ids and hints
]: nothing -> string { timew ...$rest }

# Intervals as a table with local datetimes and a computed span; the open interval has `end: null`.
#
# Without flags every interval is returned. Range hints such as `:week` pass through with the tags.
@category productivity
export def list [
  --from (-f): datetime@_datetimes # Lower bound of the range
  --to (-t): datetime@_datetimes # Upper bound of the range (needs `--from` or `--span`)
  --span (-s): duration@_durations # Range width, anchored at `--from` or ending at `--to` (default: now)
  ...tags: string@_tags # Only intervals carrying every one of these tags
]: nothing -> table<id: int, start: datetime, end: oneof<nothing, datetime>, span: duration, tags: list<string>, annotation: oneof<nothing, string>> {
  tw export ...(range {from: $from to: $to span: $span}) ...$tags | from json | hydrate
}

# The open interval, or null when nothing is tracked.
@category productivity
export def active []: nothing -> oneof<nothing, record> {
  if (tw get dom.active | str trim) == '1' { tw get dom.active.json | from json | [$in] | hydrate | first }
}

# Start an interval, closing the open one; returns the new interval.
@category productivity
export def start [
  ...tags: string@_tags # Tags for the interval
  --at (-a): datetime@_datetimes # Backdated start
]: nothing -> record {
  tw start ...([$at] | compact | each { iso }) ...$tags
  active
}

# Close the open interval; returns it, or null when nothing was tracked.
@category productivity
export def stop [
  --at (-a): datetime@_datetimes # Backdated end (after the interval's start)
]: nothing -> oneof<nothing, record> {
  if (active) == null { return null }
  tw stop
  if $at != null { tw modify end '@1' ($at | iso) }
  interval 1
}

# Adjust one interval's bounds, tags or annotation; returns the updated interval.
@category productivity
export def modify [
  id: int@_ids # Interval id (1 is the most recent)
  --start: datetime@_datetimes # New start
  --end: datetime@_datetimes # New end (closed intervals only)
  --tags: list<string> # Replacement tag set
  --annotate: string # Annotation text
]: nothing -> record {
  let ref: string = $'@($id)'
  if $start != null { tw modify start $ref ($start | iso) }
  if $end != null { tw modify end $ref ($end | iso) }
  if $tags != null {
    let old: list<string> = (interval $id).tags
    if ($old | is-not-empty) { tw untag $ref ...$old }
    if ($tags | is-not-empty) { tw tag $ref ...$tags }
  }
  if $annotate != null { tw annotate $ref $annotate }
  interval $id
}

# Tags with their usage counts.
@category productivity
export def tags []: nothing -> table<name: string, count: int> {
  $env.TIMEWARRIORDB? | default $DB | path join data tags.data
  | open --raw | from json | transpose name count | update count { get count }
}

# Intervals of the current day.
export alias today = list :day
# Intervals of the current week.
export alias week = list :week

# ——— helpers ————————————————————————————————————————————————————————————————

# Run `timew` without prompts or feedback; a non-zero exit raises its stderr.
def tw [...args: string]: nothing -> string {
  timew ...$args :yes :quiet | complete
  | if $in.exit_code != 0 { error make --unspanned $"timew ($args.0): ($in.stderr | str trim)" } else { $in.stdout }
}

# A tracked interval by id.
def interval [id: int]: nothing -> record {
  tw get $'dom.tracked.($id).json' | from json | [$in] | hydrate | first
}

def iso []: datetime -> string { date to-timezone local | format date %FT%T%:z }

# Timewarrior range arguments for the given bounds.
def range [bounds: record]: nothing -> list<string> {
  match ($bounds | compact) {
    {from: $f to: $t} => [from ($f | iso) to ($t | iso)]
    {from: $f span: $s} => [from ($f | iso) to ($f + $s | iso)]
    {from: $f} => [from ($f | iso) to (date now | iso)]
    {to: $t span: $s} => [from ($t - $s | iso) to ($t | iso)]
    {span: $s} => [from ((date now) - $s | iso) to (date now | iso)]
    {to: _} => { error make --unspanned '`--to` needs `--from` or `--span`' }
    _ => []
  }
}

# Rows of `timew export` as local datetimes with a computed span.
def hydrate []: list -> table {
  default [] tags | default null end | default null annotation
  | update start { into datetime | date to-timezone local }
  | update end { if $in != null { into datetime | date to-timezone local } }
  | insert span {|row| ($row.end | default (date now)) - $row.start }
  | select id start end span tags annotation
}

# ——— completions —————————————————————————————————————————————————————————————

def tag-rows []: nothing -> table<value: string, description: string> {
  try { tags | rename value description | update description { $'($in) intervals' } } catch { [] }
}
def id-rows []: nothing -> table<value: string, description: string> {
  try {
    list --span=4wk | each {|row|
      {value: ($row.id | into string) description: $"($row.start | format date '%m-%d %H:%M') ($row.tags | str join ' ')"}
    }
  } catch { [] }
}
def _timew [buffer: string]: nothing -> record {
  if ($buffer | split row --regex '\s+' | length) <= 2 { $COMMANDS | wrap value } else {
    [...(tag-rows) ...($HINTS | wrap value) ...(id-rows | update value { prepend '@' | str join })]
  } | into completions {sort: false}
}
def _tags []: nothing -> record { tag-rows | into completions }
def _ids []: nothing -> record { id-rows | into completions {sort: false} }
def _datetimes []: nothing -> record { $SPANS | each { (date now) - $in | iso } | into completions {sort: false} }
def _durations []: nothing -> record { $SPANS | into string | into completions {sort: false} }
