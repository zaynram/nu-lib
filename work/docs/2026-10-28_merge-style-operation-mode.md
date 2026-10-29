# Design Session - 2026-10-28

Two different answers, one per side.

**Todoist (live queries).** They run on their own, with your Todoist connection, every time the dashboard is opened, the toolbar Refresh is pressed, or a filter changes. Nothing to press on a normal open. The one prompt is the first-time connector approval for the page, which your view context shows you are already past. Settings has a "Refresh data" interval that controls how often results re-run as the page is reopened, so you can tune it from "every open" to something sparser if the three calls feel slow.

**GitHub (attached files).** Never, on its own. There is no connector to re-run, so the snapshot is exactly as old as the last upload, and the page marks it stale after a week. Until a GitHub connector exists in your registry, the refresh is a session action: `work` (or `gh`) produces the two JSON files, I upload them. If `work snapshot export` writes them into a folder you connect to a session, that becomes one message: "refresh GitHub".

## A merge-style operation mode for `work`

The git analogy holds well, and it suggests the structure. Working names below; rename freely.

**State machine.** `idle → planned → applying → done | aborted`. The plan is persisted (a `reconcile` row in the SQLite store, the equivalent of `MERGE_HEAD`), so a second invocation while one is open refuses, exactly as git does, and `--abort` always has something to abort.

**Commands.**

- `work drift` : pull both sides fresh, compute the rows, print them. Read-only, always allowed.
- `work reconcile` : `drift`, then persist the plan and enter `planned`. Prints the auto rows and the judgment rows, the latter marked unresolved, like conflict markers.
- `work resolve <key> --todoist | --github | --skip` : resolve one judgment row by choosing a side (the Fix column's two options are the side names). `--skip` leaves it on the card for next time.
- `work reconcile --continue` : refuses while any judgment row is unresolved and not skipped; otherwise applies, one action per journal entry.
- `work reconcile --abort` : before applying, discards the plan; during or after applying, reverts the journal in reverse order.
- `work reconcile --undo <run>` : same revert, for a run already completed.

**The action vocabulary is the contract.** The `fix` strings now on the card (`todoist.complete`, `todoist.priority=p1`, `todoist.label=-agent`, `github.status=Complete`, `github.project.add=<line>`, `github.milestone.close`) are the interface between three callers: the dashboard's CSV, me in a session, and `work`. Define them once as a typed record in Nu (`{target, op, arg, ref}`) and have every caller speak it. For the sigil-family labels, `todoist.label=-agent` should mean "replace any `-*` label with this one", not append; that is the semantics the convention implies.

**Optimistic concurrency, not just idempotency.** Each plan row records the observed state it was computed from (the task's current priority, the issue's current status). At apply time, re-read and compare; if the target moved since planning, mark the row stale, skip it, and report. This is `if_version` for task state, and it is what keeps a plan made at 09:00 from clobbering an edit you made at 09:30.

**Journal.** One table: run id, row key, action, before-state, after-state, applied at, reverted at. Every action in the vocabulary has a clean inverse (complete/uncomplete, label add/remove, priority restore, status restore, milestone reopen, pointer create/delete), so `--abort` and `--undo` are mechanical.

**One write path.** Once this exists, I should stop hand-applying and call `work reconcile` through the shell bridge instead. One implementation, one journal, one audit trail. The scheduled route later is `work reconcile --auto-only --yes` on a timer on your machine, which also dissolves the GitHub-token-in-the-cloud problem entirely.

**Where the rules live.** Two implementations of the drift rules now exist, the dashboard calc and (soon) `work`. Rather than deduplicate, keep both and use the dashboard as the oracle: after `work reconcile --continue`, the card must read zero auto rows. Differential testing for free. What they should share is the rule table itself, one row per kind with its condition, action and auto flag, kept as a document in the `work` repo that the calc's comments cite.

Fixture: when you are ready to use today's drift as sample data, I can regenerate the current rows as JSON from the snapshot and the Todoist state, timestamped, so the tests pin to a known base rather than the live card.

One decision shapes the rest: should the rule table be a Nushell-native file (NUON) that `work` loads at runtime, so adding a rule is data rather than code, or a plain doc that both implementations follow by hand?
