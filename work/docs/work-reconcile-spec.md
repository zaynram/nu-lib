# `work` reconcile: specification

Status: draft for the `work` rewrite. Captures the design agreed in conversation on 2026-10-27 to 2026-11-03 so the current rewrite scope does not have to absorb it yet. Everything here is a proposal to be ratified or amended when the module reaches this feature.

## 1. Purpose

`work` is the single write path for keeping Todoist and GitHub aligned under the convention. It computes drift (the same rules the Engineering Review dashboard shows), stages a reconciliation plan, applies it transactionally, journals every write, and can abort or undo. The dashboard remains the read model and the oracle: after a successful `work reconcile --continue`, the dashboard's convention-settled drift count must read zero.

Non-goals: no UI; no scheduled execution inside the module (a timer calls it); no judgment calls (ambiguous drift is surfaced, never guessed).

## 2. Systems of record

| Concern | Record | Derived copy |
|---|---|---|
| Scope, structure, relationships (issue, parent, milestone, type, Status) | GitHub | Todoist pointer task and its section |
| Work state, including blocked | GitHub Status (`Pending` is the only record of blocked; `:blocked` is retired) | none |
| Priority, Effort, Executor, Maturity of engineering issues | GitHub issue fields (Effort is not mirrored) | Todoist `p1`–`p4`, `-human/-agent/-mixed`, `?stub/?seed` |
| Scheduling, non-code work, horizon (`^next`, `^upcoming` on Release tasks) | Todoist | none |
| Focus (`:current` on one task; `:ready` on each project's next action) | Todoist; the dashboard is where work is picked | GitHub Status `In Progress` follows `:current` |
| Release-bound vs unbound | Derived: a pointer whose issue sits in a release milestone, or a subtask of a Release task, is bound; the dashboard shows bound next actions under Releases and unbound ones under Backlog, and the Standup's "on deck" is the `:ready` items inside `^next` releases only | none |
| Placement (line / Releases, line / Operations, repo subproject / Chores, Next, Upcoming) | Convention, enforced from GitHub type and horizon | Todoist section |
| Time | timewarrior | none (read-only input to the dashboard) |

Personal repos (zaynram) stay personal and field-less (decided 2026-11-02): rules that read types or fields skip them.

The pointer task is the only shared object. Its description carries the issue URL, which is the join key. A Release task (`name@vX.Y.Z`) joins a milestone titled `name_vX.Y.Z` or, within repo `name`, `vX.Y.Z`. A release milestone is one whose title matches `_v<digit>` or starts with `v<digit>`; thematic milestones (daisy-theoretics, academic-foundation) are tracks, not horizons, and the horizon rules leave them alone.

## 3. Rule table

One row per drift kind, grouped as the dashboard computes them. `auto` means the convention settles the fix. Conditions are evaluated over a fresh pull of both sides. Constants: `READY_PER_PROJECT = 1`. Focus is counted over every open task outside the errands tree; horizon and placement rules apply within the engineering lines only.

### Pointer ↔ issue (GitHub owns fields and state)

| Kind | Condition | Fix (auto) | Options (judgment) |
|---|---|---|---|
| Pointer open, issue closed | task open, issue `CLOSED` | `todoist.complete` | |
| Pointer to unknown issue | task URL not in the pull, repo is in `repos.nuon` | `snapshot.refresh` | |
| Pointer to untracked repo | task URL names a repo not in `repos.nuon` | | Todoist: retire the pointer / Snapshot: add the repo to repos.nuon |
| Executor mismatch | issue `exec` set and task lacks `-<exec>` | `todoist.label=-<exec>` | |
| Maturity mismatch | issue `mat` set and task lacks `?<mat>` | `todoist.label=?<mat>` | |
| Priority mismatch | issue `prio` set and task priority differs | `todoist.priority=<p>` (Urgent p1, High p2, Medium p3, Low p4) | |

### GitHub-internal

| Kind | Condition | Fix (auto) | Options (judgment) |
|---|---|---|---|
| Issue without pointer | open issue, no task URL matches | | Todoist: create pointer in the line's tree / GitHub: close as not planned |
| Closed, status not terminal | issue `CLOSED`, Status not `Complete`/`Abandoned` | `github.status=Complete` (or `Abandoned` when `NOT_PLANNED`) | |
| Not in a project | open org issue with no project item | `github.project.add=<line>` | |
| Milestone complete but open | milestone `OPEN`, open issues 0, closed > 0 | `github.milestone.close` | |
| Milestone without Release task (H2) | release milestone `OPEN` with open issues and no Release task names it | | Todoist: create the Release task in line / Releases / GitHub: close the milestone |

### Release tasks and horizon

| Kind | Condition | Fix (auto) | Options (judgment) |
|---|---|---|---|
| Release task without milestone | `name@v…` task, repo has a remote, no matching milestone | | GitHub: create milestone / Todoist: retire the task |
| More than one ^next in a line (H1) | two or more `^next` Release tasks under one line project | | Todoist: keep `^next` on the release in play, `^upcoming` on the rest |
| Focus label on a Release task (H3) | Release task carries `:current` or `:ready` | `todoist.unlabel=<label>` | |
| Release task misplaced (S1a) | Release task not in line project / Releases | `todoist.move=<line>/Releases` | |

### Focus (Todoist owns; one person, one focus)

| Kind | Condition | Fix (auto) | Options (judgment) |
|---|---|---|---|
| More than one :current (F1) | `:current` on more than one issue pointer | | Todoist: keep one |
| Nothing lined up (F2) | no `:current` and no `:ready` | | Todoist: mark one `:current` or each project's next action `:ready` |
| More than one :ready in a project (F3) | two or more `:ready` tasks in one Todoist project | | Todoist: keep `:ready` on the project's next action |
| Focus on blocked work (F4) | `:current`/`:ready` pointer whose issue is `Pending` | `todoist.unlabel=<label>` | |
| Focus on finished work (F6) | `:current`/`:ready` pointer whose issue is closed, `Reviewed`/`Complete`/`Abandoned`, or in a closed milestone | `todoist.unlabel=<label>` | |
| Current but not In Progress (F5) | `:current` pointer whose issue Status is not `In Progress` | `github.status=In Progress` (the one Todoist→GitHub write) | |
| Focus outside the release in play (F7) | `:current` pointer whose issue is in a release milestone no `^next` task names | | Todoist: move `^next` or refocus / GitHub: move the issue |
| :blocked is retired (F8) | any task carries `:blocked` | `todoist.unlabel=:blocked` | |

### Placement (subtasks follow their parent)

| Kind | Condition | Fix (auto) | Options (judgment) |
|---|---|---|---|
| Non-chore in Operations (S1b) | pointer in a line project's Operations whose issue type is not `chore` | | Todoist: move to the repo's subproject (open question: where line-repo issues live, §9) |
| Pointer in the wrong section (S1c) | pointer in a subproject whose expected section (type `chore` → Chores; milestone `^next` → Next; `^upcoming` → Upcoming) differs | `todoist.move=<project>/<section>` | |

Signal, not drift: the week's dominant tracked project versus the `:current` pointer's repo is shown in the dashboard's "This week" line (T1).

Amendments to these tables are the only place the convention changes. The dashboard's drift calculation mirrors them; both cite this file.

## 4. Action vocabulary

The contract between the dashboard's CSV export, a Claude session, and `work`. One typed record per action:

```nu
# { target: todoist | github | snapshot, op: string, arg: any, ref: string }
# ref: Todoist task id for todoist.*, issue/milestone URL for github.*
```

| Action string | Semantics | Inverse |
|---|---|---|
| `todoist.complete` | complete task `ref` | `uncomplete` |
| `todoist.create` | create pointer task; `arg` = {project, section, parent, content, labels, priority, description} | delete |
| `todoist.rename` | set content | restore previous |
| `todoist.priority=pN` | set priority | restore previous |
| `todoist.label=<sigil><value>` | replace the label of that sigil family (`-`, `?`, `:`), keep others | restore previous label set |
| `todoist.unlabel=<label>` | remove one label | restore it |
| `todoist.move=<project>/<section>` | move the task to that project and section (`line/Releases`, `repo/Chores`, …) | restore previous project and section |
| `todoist.parent` | re-parent; `arg` = parent task id or issue URL (resolved to the pointer) | restore previous parent |
| `github.status=<Status>` | set project Status on the item (`In Progress` from `:current` is the one Todoist-driven case) | restore previous |
| `github.project.add=<line>` | add issue to the line's project | remove item |
| `github.milestone.close` | close milestone | reopen |
| `snapshot.refresh` | re-run the GitHub pull before judging | none |

Sigil-family replacement is the semantics the convention implies: a task has at most one executor, one maturity, one state.

## 5. Operation mode

State machine: `idle → planned → applying → done | aborted`. The plan is persisted (a `reconcile` table row with a run id), so a second `reconcile` while one is open refuses, and `--abort` always has something to abort.

```
work drift                    read both sides, print rows (read-only, always allowed)
work reconcile                drift, persist plan, enter `planned`; print auto rows and unresolved judgment rows
work resolve <key> --todoist | --github | --skip
                              resolve one judgment row by choosing a side (the Fix column's two options); --skip leaves it for next time
work reconcile --continue     refuse while an unresolved judgment row exists; otherwise apply, journaling each action
work reconcile --abort        before apply: discard plan; during/after: revert journal in reverse
work reconcile --undo <run>   revert a completed run
work reconcile --auto-only --yes
                              non-interactive: apply auto rows, skip all judgment rows (the timer's mode)
```

### Optimistic concurrency

Each plan row stores the observed state it was computed from (the task's current priority, labels, parent; the issue's Status, milestone state). At apply time the target is re-read and compared; if it moved since planning, the row is marked `stale`, skipped, and reported. A plan made at 09:00 must not clobber an edit made at 09:30.

### Idempotency

Every action is safe to repeat: completing a completed task, setting a label already present, adding an item already in the project are no-ops that still journal `applied: false, reason: already`.

## 6. Storage

SQLite, in the module's existing store.

```sql
CREATE TABLE reconcile_run (
  id TEXT PRIMARY KEY, started_at TEXT, finished_at TEXT,
  state TEXT CHECK (state IN ('planned','applying','done','aborted')),
  github_pulled_at TEXT, todoist_pulled_at TEXT, mode TEXT
);
CREATE TABLE reconcile_row (
  run_id TEXT REFERENCES reconcile_run(id), key TEXT, kind TEXT, item TEXT, detail TEXT,
  auto INTEGER, action TEXT, arg TEXT, ref TEXT, task_id TEXT, issue_url TEXT,
  observed TEXT,             -- JSON of the state the row was computed from
  resolution TEXT,           -- null | todoist | github | skip  (judgment rows)
  status TEXT,               -- pending | applied | stale | skipped | failed | reverted
  PRIMARY KEY (run_id, key)
);
CREATE TABLE reconcile_journal (
  id INTEGER PRIMARY KEY, run_id TEXT, key TEXT, action TEXT, ref TEXT,
  before TEXT, after TEXT,   -- JSON
  applied_at TEXT, reverted_at TEXT, error TEXT
);
```

## 7. Integrations

- Todoist: `td` (JSON output) via the existing `todo` module. Pointers are found by regex on description: `https://github.com/<owner>/<repo>/issues/<n>`.
- GitHub: `gh api graphql`, same query the dashboard snapshot uses (issues with type, labels, milestone, parent, issue fields, project items). Needs `repo` + `project` scopes.
- Dashboard: `work snapshot export [dir]` produces `github-issues.json`, `github-milestones.json`, `timew-intervals.json`, `snapshot-meta.json` (with the repo list and repo→line map from `repos.nuon`) and `todoist-sections.json` (via `td`). Today this lives at `~/.cache/dash/export.nu` with `~/.cache/dash/repos.nuon` beside it, and the daily scheduled task runs it; moving it into `work` is a rename, not a redesign. An on-demand run is what makes a same-day GitHub close show in the Standup before the next 05:05 refresh. The dashboard's drift CSV (Sources download) is a valid `reconcile` plan input for testing.

## 8. Fixtures and tests

- `drift-fixture-2026-10-29.json`: the first captured plan, in the action vocabulary (18 auto rows, 2 judgment rows). Use as the parser/planner fixture.
- `drift-plan-2026-11-03.json`: the plan under the focus/horizon/placement rules (13 auto, 10 judgment), captured before anything was applied; covers `unlabel` and `move`.
- Differential test: run `work drift` and compare row keys against the dashboard's drift calc on the same snapshot; the sets must match. Disagreement means the rule table has forked.
- Property: `reconcile --continue` followed by `work drift` yields zero auto rows (judgment rows may remain).
- Property: `--undo <run>` restores every `before` state; a second `work drift` reproduces the original plan's auto rows.

## 9. Open questions

1. Rule table as data (NUON loaded at runtime) or as code? Data makes amendments cheap and lets the dashboard calc and `work` load the same file; code keeps conditions expressive. Decision pending.
2. Decided 2026-11-03: blocked lives only in GitHub Status `Pending`; `:blocked` is retired (F8). `:ready` is one per Todoist project (the global cap was dropped after looking at the data: twelve readies in twelve projects); `^next` at most one per line; F5 is an auto Todoist→GitHub write; placement rules S1 are auto except S1b.
3. Decided 2026-11-02: personal repos (zaynram) stay personal and field-less. Rules that read issue types or fields skip them; Todoist labels are the only carrier of executor, maturity and priority on those lines, and the dashboard treats them as Todoist-owned for everything except issue existence and milestones.
4. Should `todoist.create` for "Issue without pointer" ever be auto? Today it is judgment because section placement and priority need a human; a default placement rule per line would make it auto.
5. Where do a line repo's own non-chore issues live in Todoist (legal-marketplace#55, daisy#13)? Today they sit in the line's Operations, which S1b flags. Either a subproject per line repo, or Operations admits the line repo's issues alongside global chores. Decision pending; S1b stays judgment until then.
6. Timer cadence and host: `--auto-only --yes` on a systemd timer in WSL is the natural fit once the module is trusted; until then the session is the operator.
