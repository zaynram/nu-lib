# `time`: Timewarrior wrapper

Module `_internal/time`. Consumer: `~/.config/nushell/login.nu` (`use time`). Replaces the `time`
submodule of `_internal/warrior`; that umbrella is gone, its Todoist half lives in `_internal/todo`.

## Purpose

`time` wraps the Timewarrior CLI for scripting. Intervals come back as Nushell tables with local
datetimes and a computed span, datetime and duration values convert to Timewarrior literals, and
completions cover subcommands, tags, interval ids and range hints.

## Scope

Removed: `desc`, `span`, `line` and its `--then` closure, the `cont`, `docs` and `show` aliases, and
every Taskwarrior definition (`task add`, `task swap`, `mkargs`, `str chrono`, `resolve-repo-root` and
the Taskwarrior completers). Only `warrior time` had a consumer, and `warrior` itself is removed.

Kept: the raw passthrough `main` and `tags`.

Added: `list`, `active`, `start`, `stop`, `modify`, and the aliases `today` and `week`.

## Contract

# Pass arguments straight to `timew`; completions cover subcommands, tags, ids and hints.
export def --wrapped main [...rest: string@_timew]: nothing -> string

# Intervals as a table with local datetimes and a computed span; the open interval has `end: null`.
export def list [
  --from (-f): datetime@_datetimes
  --to (-t): datetime@_datetimes
  --span (-s): duration@_durations
  ...tags: string@_tags
]: nothing -> table<id: int, start: datetime, end: oneof<nothing, datetime>, span: duration, tags: list<string>, annotation: oneof<nothing, string>>

# The open interval as a `list` row (`end: null`), or null when nothing is tracked.
export def active []: nothing -> oneof<nothing, record>

# Start an interval, closing the open one; returns the new interval.
export def start [...tags: string@_tags --at (-a): datetime@_datetimes]: nothing -> record

# Close the open interval; returns it, or null when nothing was tracked.
export def stop [--at (-a): datetime@_datetimes]: nothing -> oneof<nothing, record>

# Adjust one interval's bounds, tags or annotation; returns the updated interval.
export def modify [id: int@_ids --start: datetime --end: datetime --tags: list<string> --annotate: string]: nothing -> record

# Tags with their usage counts.
export def tags []: nothing -> table<name: string, count: int>

export alias today = list :day
export alias week = list :week
```

## Behaviour

- `list` without flags returns every interval. Range hints such as `:week` pass through with the tags.
- `--from`, `--to` and `--span` compose into `from <iso> to <iso>`: `from` alone ends now, `span`
  alone ends now, `from` with `span` ends at `from + span`, `to` with `span` starts at `to - span`,
  `from` with `to` ignores `span`. `--to` alone is an error.
- Rows carry `id start end span tags annotation`. `end` and `annotation` are null when Timewarrior
  omits them, `tags` defaults to an empty list, `span` is `end` (or now) minus `start`.
- `start --at` backdates the start. `stop --at` runs `timew stop` and then moves the end, because
  `timew stop` takes no date and `timew modify end` refuses an open interval.
- `modify --tags` replaces the tag set by untagging the current tags and tagging the new ones.
- `tags` reads `<db>/data/tags.data`; `$env.TIMEWARRIORDB` overrides the database root, which
  defaults to `~/.local/share/timewarrior`.
- Every `timew` call the module makes runs with `:yes :quiet`. A non-zero exit raises the stderr text.
- Datetimes are passed as local ISO timestamps with a zone offset; Timewarrior accepts that form for
  `start`, ranges and `modify`.

## Naming

`export` is a parser keyword and cannot name a command, so the structured export is `list`.

## Verification

`nu time/tests/time.nu` exercises every command against a scratch `TIMEWARRIORDB`. Static checks:
`nu --ide-check` and `nu-lint` report nothing for `time/mod.nu`.
