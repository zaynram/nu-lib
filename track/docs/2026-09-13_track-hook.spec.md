# `track`: automatic time tracking of the focused repository

Module `_internal/track`. Depends on `_internal/time` and `_internal/todo`. Registered by the hook
manifest `~/.config/nushell/autoload/hooks.nu`; `~/.config/nushell/login.nu` imports it (`use track`)
so the hook strings resolve in the shell scope.

## Purpose

Every command a shell runs keeps the open Timewarrior interval aligned with that shell's focus: the
repository it sits in, tagged with the Todoist task whose content best matches the current branch,
or with the branch name when nothing matches. The zellij session is the unit of work and the most
recent command anywhere decides what is tracked.

## Decisions

- **Timewarrior is the only state.** There is no session map. Each shell caches its focus in
  `$env.TRACK` and compares it with the open interval on every command; the most recent command wins.
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
- **Errors switch the shell off, once.** A failing `timew` call prints one line and disables tracking
  in that shell until its next directory change; the prompt never breaks.
- **Logic lives in the module, registration in the manifest.** `hooks.nu` stays the single list of
  hooks; modules supply behaviour that is worth testing. The other hooks in the manifest are glue and
  stay where they are.

## Contract

```nu
# This shell's focus, cached in `$env.TRACK`.
export def --env focus [--refresh (-r)]: nothing -> oneof<nothing, record<root: oneof<nothing, path>, repo: string, head: path, branch: string, task: oneof<nothing, string>, tags: list<string>, matches: record>>

# Align the open Timewarrior interval with this shell's focus; the pre_execution hook body.
export def --env sync [--idle: duration = 30min]: nothing -> nothing
```

`time db` was added alongside: it returns the Timewarrior database root in use.

## Behaviour

- `focus --refresh` runs `git rev-parse --show-toplevel --absolute-git-dir`. Outside a repository the
  cache becomes `{root: null}`. Inside, the branch is read from `<git-dir>/HEAD`, or the short commit
  hash when detached, and `todo find <branch> --project <repo>` supplies the task. A failing `todo`
  call, including an unknown project, yields no task.
- `sync` refreshes the focus when the cache is empty or the HEAD file no longer names the cached
  branch, returns outside a repository or when the shell is disabled, then compares tags as sets.
- Timewarrior drops intervals shorter than a second, so a checkout within a second of the previous
  start leaves no trace of the first interval. That is Timewarrior's behaviour, not a bug.

## Registration

```nu
# hooks.nu, pre_execution
[`track::sync` {|| is-enabled track::sync } 'track sync']
# hooks.nu, env_change.PWD
[`track::focus` false {|_ pwd| is-enabled track::focus } 'track focus --refresh | ignore']
```

Hook code is a string because a closure cannot update `$env.TRACK` in the shell. Set `disabled` on
either entry with `hook edit` to switch tracking off.

## Verification

`nu track/tests/track.nu` runs against a scratch Timewarrior database and a scratch repository: focus
in and out of a repository, the first interval, no restart on the same focus, checkout detection, the
idle trim, and the no-op outside a repository. Static checks: `nu --ide-check` and `nu-lint` report
nothing for `track/mod.nu`. The live hook firing in an interactive shell is verified by use, not by
this test.
