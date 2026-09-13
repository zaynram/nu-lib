# `todo`: Todoist tasks over `td`

Module `_internal/todo`. Replaces the Taskwarrior submodule of the former `_internal/warrior`; the
name avoids `task`, which is Taskwarrior's binary. Shared helper: `util with-auth`.

## Purpose

`todo` wraps the Todoist CLI (`td` 5.x) for scripting: tasks come back as flat rows with the project
name resolved and `due` as a datetime, writes return the resulting row, every call retries once after
an interactive login when `td` reports an auth failure, and `find` matches a branch name or slug
against a project's tasks. The tracking hook (next session) and the `dev` sync consume `find`,
`list`, `add`, `edit` and `done`.

## Contract

```nu
# util/mod.nu
# Run an external command and return its stdout. On an auth failure in an interactive session run
# `--login` once and retry; any other non-zero exit raises the captured output.
export def --wrapped with-auth [
  --login (-l): closure
  --pattern: string = '(?i)\b(401|403|unauthori[sz]ed|not (logged in|authenticated)|auth login)\b'
  ...cmd: string
]: nothing -> string
```

# Pass arguments to `td`; `--json` and `--ndjson` output is parsed.
export def --wrapped main [...rest: string@_td]: nothing -> any

# Tasks as rows.
export def list [
  --project (-p): string@_projects
  --label (-l): list<string>@_labels
  --parent: string@_tasks
  --filter (-f): string
  --completed (-c)
  --since: datetime
]: nothing -> table<id: string, content: string, description: string, labels: list<string>, project: string, parent: oneof<nothing, string>, due: oneof<nothing, datetime>, priority: int, url: string>

export def view [ref: string@_tasks]: nothing -> record
export def add [
  content: string
  --project (-p): string@_projects
  --description (-d): string
  --labels (-l): list<string>@_labels
  --parent: string@_tasks
  --due: oneof<datetime, string>
  --priority: int
]: nothing -> record
export def edit [
  ref: string@_tasks
  --content: string
  --description (-d): string
  --labels (-l): list<string>@_labels
  --due: oneof<datetime, string>
  --no-due
  --priority: int
]: nothing -> record
export def done [...refs: string@_tasks]: nothing -> nothing
export def reopen [...refs: string@_tasks]: nothing -> nothing
export def rm [...refs: string@_tasks]: nothing -> nothing
export def browse [ref: string@_tasks]: nothing -> nothing
export def projects []: nothing -> table<id: string, name: string, url: string>
export def labels []: nothing -> table<id: string, name: string>

# Best-effort match of a slug against candidate rows (pipeline input) or the project's open tasks.
export def find [
  slug: string
  --project (-p): string@_projects
  --threshold: float = 0.5
]: oneof<nothing, table> -> oneof<nothing, record<id: string, content: string, score: float, url: string>>
```

## Behaviour

- A task reference is an id, `id:<id>`, or the exact task content. `td` resolves all three.
- Rows: `project` is the project name. When `list` is called with `--project` the name is used as is;
  otherwise one extra `td project list` call resolves ids to names. `parent` is the parent task id.
  `due` is `due.date` parsed as a datetime. `priority` uses the app's vocabulary, 1 for p1 (urgent)
  through 4 for p4, which is `5 - api_priority`.
- `list --completed` runs `td completed list`, whose window defaults to today and spans at most three
  months; `--since` sets the lower bound. Completed rows have the same shape.
- `add --due` and `edit --due` format a datetime as `YYYY-MM-DD`; a string passes through as the
  Todoist due string.
- `done`, `reopen` and `rm` loop over their references; `rm` passes `--yes`.
- `find` scores an exact content match as 1. Otherwise it lowercases both strings, splits them on
  `-`, `/`, `@` and `.`, and scores the Jaccard overlap of the token sets. Candidates below the
  threshold are dropped; the highest score wins; a tie for the top score yields null. Without pipeline
  input the candidates are `list --project`, and without `--project` the project is the basename of
  the repository root, or an error outside a repository.
- Every `td` call goes through `with-auth`. `td` writes errors as JSON to stderr with exit code 1, and
  reports auth failures with a `td auth login` hint, which the default pattern matches.
- `with-auth` never prompts outside interactive sessions; it raises instead.

## Naming

The edit command is `edit`, not `update`. A module's exported names are predeclared before its
imports are parsed, so an exported `update` would shadow the builtin inside `util` and break its
parse. The same rule keeps `rm` and `find` out of any module this one imports.

## Completions

`_td` rewrites the buffer to a `td` line for the external completer and falls back to the top-level
`td` command list when that returns nothing. `_projects`, `_labels` and `_tasks` query `td` live.

## Verification

`nu todo/tests/todo.nu` checks the matcher offline against fixture rows and the read commands
against the live account. Setting `WARRIOR_TASK_WRITE=1` additionally runs add, edit, done,
reopen and rm on a throwaway task in Inbox. Static checks: `nu --ide-check` and `nu-lint` report
nothing for `todo/mod.nu` and `util/mod.nu`.
