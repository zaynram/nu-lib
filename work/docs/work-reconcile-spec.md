# `work` reconcile: specification

Status: draft for the `work` rewrite. Captures the design agreed in conversation on 2026-10-27 to 2026-10-30 so the current rewrite scope does not have to absorb it yet. Everything here is a proposal to be ratified or amended when the module reaches this feature.

## 1. Purpose

`work` is the single write path for keeping Todoist and GitHub aligned under the convention. It computes drift (the same rules the Engineering Review dashboard shows), stages a reconciliation plan, applies it transactionally, journals every write, and can abort or undo. The dashboard remains the read model and the oracle: after a successful `work reconcile --continue`, the dashboard's convention-settled drift count must read zero.

Non-goals: no UI; no scheduled execution inside the module (a timer calls it); no judgment calls (ambiguous drift is surfaced, never guessed).

## 2. Systems of record

| Concern                                                                  | Record                                                          | Derived copy |
|--------------------------------------------------------------------------|-----------------------------------------------------------------|--------------|
| Scope, structure, relationships (issue, parent, milestone, type, Status) | GitHub                                                          | Todoist pointer task and its section/labels |
| Priority, Effort, Executor, Maturity of engineering issues               | GitHub issue fields                                             | Todoist `p1`–`p4`, `-human/-agent/-mixed`, `?stub/?seed` |
| Scheduling, non-code work, horizon (`^next`, `^upcoming`)                | Todoist                                                         | none         |
| Blocked state                                                            | Both, by design (Todoist `:blocked` vs GitHub Status `Pending`) | neither; mismatch is a judgment row |
| Time                                                                     | timewarrior                                                     | none (read-only input to the dashboard) |

The pointer task is the only shared object. Its description carries the issue URL, which is the join key. A Release task (`name@vX.Y.Z`) joins a milestone titled `name_vX.Y.Z` or, within repo `name`, `vX.Y.Z`, and points at the release-chore issue.

## 3. Rule table

One row per drift kind. `auto` means the convention settles the fix. Conditions are evaluated over a fresh pull of both sides.

| Kind                           | Condition                                            | Fix (auto)                                                     | Options (judgment) |
|--------------------------------|------------------------------------------------------|----------------------------------------------------------------|--------------------|
| Pointer open, issue closed     | task open, issue `CLOSED`                            | `todoist.complete`                                             |                    |
| Pointer to unknown issue       | task URL not in GitHub pull                          | `snapshot.refresh`                                             |                    |
| Executor mismatch              | issue `exec` set and task lacks `-<exec>`            | `todoist.label=-<exec>`                                        |                    |
| Maturity mismatch              | issue `mat` set and task lacks `?<mat>`              | `todoist.label=?<mat>`                                         |                    |
| Priority mismatch              | issue `prio` set and task priority differs           | `todoist.priority=<p>` (Urgent p1, High p2, Medium p3, Low p4) |                    |
| Status mismatch                | issue Status `In Progress` and task lacks `:current` | `todoist.label=:current`                                       |                    |
| Parent mismatch                | issue parent has a pointer and task parent differs   | `todoist.parent`                                               |                    |
| Blocked mismatch               | Status `Pending` xor task `:blocked`                 |                                                                | Todoist: toggle `:blocked` / GitHub: set Status |
| Issue without pointer          | open issue, no task URL matches                      |                                                                | Todoist: create pointer in the line's tree / GitHub: close as not planned |
| Closed, status not terminal    | issue `CLOSED`, Status not `Complete`/`Abandoned`    | `github.status=Complete` (or `Abandoned` when `NOT_PLANNED`)   |                    |
| Not in a project               | open org issue with no project item                  | `github.project.add=<line>`                                    |                    |
| Milestone complete but open    | milestone `OPEN`, open issues 0, closed > 0          | `github.milestone.close`                                       |                    |
| Release task without milestone | `name@v...` task with no matching milestone          |                                                                | GitHub: create milestone / Todoist: retire the task |
| Release task renamed in GitHub | release-chore issue title differs from task name     |                                                                | Todoist: rename and point / GitHub: rename issue and milestone |

Amendments to this table are the only place the convention changes. The dashboard's drift calculation mirrors it; both cite it.

## 4. Action vocabulary

The contract between the dashboard's CSV export, a Claude session, and `work`. One typed record per action:

```nu
# { target: todoist | github | snapshot, op: string, arg: any, ref: string }
# ref: Todoist task id for todoist.*, issue/milestone URL for github.*
```

| Action string                  | Semantics                                                                                       | Inverse |
|--------------------------------|-------------------------------------------------------------------------------------------------|---------|
| `todoist.complete`             | complete task `ref`                                                                             | `uncomplete` |
| `todoist.create`               | create pointer task; `arg` = {project, section, parent, content, labels, priority, description} | delete  |
| `todoist.rename`               | set content                                                                                     | restore previous |
| `todoist.priority=pN`          | set priority                                                                                    | restore previous |
| `todoist.label=<sigil><value>` | replace the label of that sigil family (`-`, `?`, `:`), keep others                             | restore previous label set |
| `todoist.parent`               | re-parent; `arg` = parent task id or issue URL (resolved to the pointer)                        | restore previous parent |
| `github.status=<Status>`       | set project Status on the item                                                                  | restore previous |
| `github.project.add=<line>`    | add issue to the line's project                                                                 | remove item |
| `github.milestone.close`       | close milestone                                                                                 | reopen  |
| `snapshot.refresh`             | re-run the GitHub pull before judging                                                           | none    |

Sigil-family replacement is the semantics the convention implies: a task has at most one executor, one maturity, one state.

## 5. Operation mode

State machine: `idle → planned → applying → done | aborted`. The plan is persisted (a `reconcile` table row with a run id), so a second `reconcile` while one is open refuses, and `--abort` always has something to abort.

```_
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
- Dashboard: `work snapshot export [dir]` produces `github-issues.json`, `github-milestones.json`, `timew-intervals.json`, `snapshot-meta.json`. Today this lives at `~/.cache/dash/export.nu`, standalone, and the daily scheduled task runs it; moving it into `work` is a rename, not a redesign. The dashboard's drift CSV (Sources download) is a valid `reconcile` plan input for testing.

## 8. Fixtures and tests

- `drift-fixture-2026-10-29.json`: the first captured plan, in the action vocabulary (18 auto rows, 2 judgment rows). Use as the parser/planner fixture.
- Differential test: run `work drift` and compare row keys against the dashboard's drift calc on the same snapshot; the sets must match. Disagreement means the rule table has forked.
- Property: `reconcile --continue` followed by `work drift` yields zero auto rows (judgment rows may remain).
- Property: `--undo <run>` restores every `before` state; a second `work drift` reproduces the original plan's auto rows.

## 9. Open questions

1. Rule table as data (NUON loaded at runtime) or as code? Data makes amendments cheap and lets the dashboard calc and `work` load the same file; code keeps conditions expressive. Decision pending.
2. Where does `:blocked` truth live? Today it is a judgment row by design. If a side is chosen as record, the row becomes auto.
3. Personal repos (zaynram) have no org issue types or fields; rules that read them skip. Should personal repos move into an org to remove the gap, or stay field-less?
4. Should `todoist.create` for "Issue without pointer" ever be auto? Today it is judgment because section placement and priority need a human; a default placement rule per line would make it auto.
5. Timer cadence and host: `--auto-only --yes` on a systemd timer in WSL is the natural fit once the module is trusted; until then the session is the operator.
