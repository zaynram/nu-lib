# `track`: automatic time tracking of the focused repository

Module `track`. Depends on `time`, `todo` and `hook`. `use track` registers its two hooks itself
(see Registration).

## Purpose

Every command a shell runs keeps the open Timewarrior interval aligned with that shell's focus: the
repository it sits in, tagged with the Todoist task whose content best matches the current branch,
or with the branch name when nothing matches. The zellij session is the unit of work and the most
recent command anywhere decides what is tracked.

## Decisions

- **Timewarrior is the only state.** There is no session map. Each shell caches its focus in
  `$env.TRACK` and compares it with the open interval on every command; the most recent command wins.
  The one value shared by all shells is the `disabled` switch, in `kv --universal --table=track`.
- **The hot path is one file read and one `timew` call.** The focus cache holds the path of the
  repository's HEAD file, and `sync` reads it to notice checkouts. Matching runs only when the
  repository or branch changes, and its result is cached per shell for an hour.
- **Tags follow the existing vocabulary.** An interval carries `#<repo>` plus the matched task
  content, or the branch name. The session name is not tagged; it equals the repository name under
  `zellij::cd-switch-session`.
- **An idle cap trims abandoned intervals.** A stamp file inside the Timewarrior database root is
  touched per command. When the gap exceeds the cap and the open interval started before the stamp,
  the interval ends at the stamp before a new one starts.
- **Outside a repository nothing happens.** The last focus keeps accruing until another repository
  takes over or the idle cap ends it.
- **Errors switch tracking off, once.** A failing `timew` call prints one line and sets the shared
  `disabled` switch, which turns tracking off in every shell until the next focus refresh (a directory
  change out of the repository, a checkout, or a new shell); the prompt never breaks.
- **The module registers its own hooks.** `use track` adds them with `hook add --dedupe`, so importing
  it twice (e.g. through the barrel and directly) does not run `sync` twice per command.

## Contract

```nu
# This shell's focus, cached in `$env.TRACK`.
export def --env focus [--refresh (-r)]: nothing -> oneof<nothing, record>
# {root: path, repo: string, head: path, branch: string, task: oneof<nothing, string>, tags: list<string>, matches: record}
# or, outside a repository, {root: null, matches: record}

# Align the open Timewarrior interval with this shell's focus; the pre_execution hook body.
export def --env sync [--idle: duration = 30min]: nothing -> nothing
```

`time db` was added alongside: it returns the Timewarrior database root in use.

## Behaviour

- `focus --refresh` drops the `disabled` switch and runs `git rev-parse --show-toplevel --absolute-git-dir`.
  Outside a repository the cache becomes `{root: null}` (plus the match cache). Inside, the branch is
  read from `<git-dir>/HEAD`, or the short commit hash when detached, and `todo find <branch> --project
  <repo>` supplies the task; matches are cached per `<repo>@<branch>` for an hour. A failing `todo`
  call, including an unknown project, yields no task.
- `sync` refreshes the focus when the cache is empty or the HEAD file no longer names the cached
  branch (or cannot be read), returns outside a repository or while disabled, then compares tags as
  sets.
- Timewarrior drops intervals shorter than a second, so a checkout within a second of the previous
  start leaves no trace of the first interval. That is Timewarrior's behaviour, not a bug.

## Registration

`use track` runs, in its `export-env`:

```nu
add --dedupe pre_execution {
  name: 'track::sync'
  condition: {|| is-enabled --name=track::sync }
  code: {|| sync }
}
add --dedupe env_change.PWD {
  name: 'track::focus'
  condition: {|_ pwd| (is-enabled --name=track::focus) and not ($pwd | is-within $env.TRACK?.root?) }
  code: {|| focus --refresh | ignore }
}
```

Hook closures keep their environment changes, so `focus`/`sync` (`def --env`) update `$env.TRACK` in
the shell. The PWD hook fires when the new directory is not the focused root or below it (a path
prefix check, so `/w/ab` is not inside `/w/a`). Set `disabled` on either entry with `hook edit` to
switch tracking off.

## Verification

`test _tests/suites/track.nu` runs against a scratch Timewarrior database, a scratch repository and a
`td` stub: hook registration and conditions, focus in and out of a repository (detached, matched task,
match cache), the first interval, no restart on the same focus, checkout detection, the idle trim, the
no-op outside a repository, and the disable/re-enable cycle. Static checks: `nu --ide-check` and `nu-lint` report
nothing for `track/mod.nu`. The live hook firing in an interactive shell is verified by use, not by
this test.
