# 05 — Plan: redesign the issue tooling as `_internal/dev`

> Reconciled with `dev/docs/2026-09-15_dev-core.spec.md` on 2026-09-18 (sync model: Todoist owns tickets and rows, the file owns the body, the remote host is a projection; version targets in scope). Where the two differ, the spec's Decisions section is authoritative. The ownership map and lifecycle trace are `06-ownership.d2` and `07-lifecycle.d2` beside this file.

Input: `04-handoff-prompt.md` (verdict REDESIGN 8/30, v4 schema, seven `dev` contracts, decisions). Each phase below runs in a fresh session. Start every session by reading the files under its "Read first" list; nothing else from this audit is assumed to be in context.

Branch: `feat/dev-module`, branched from `main` (the util split merged; main is 40587f1). The library reorganisation of 2026-09-18 (`todo` wrapper, `prelude`, `elevate with-auth`, `util contains`/`attempt`) sits on `refactor/todo-prelude` at ffd8eb0, cut from main and not yet merged; rebase `feat/dev-module` onto main once it lands, before Phase 2 starts, because Phase 0 below cites the reorganised signatures. Commit per completed phase. Never push without an explicit request.

## Phase 0 — Documentation discovery (completed 2026-09-14)

All items below were verified by running the command named, not assumed.

### Allowed APIs

Nushell 0.115.2 builtins, confirmed with `which`: `mktemp`, `path self`, `to md`, `to toml`, `from toml`, `into datetime`, `format date`, `into cell-path`; plus `open`, `save`, `mv`, `glob`, `input`, `error make --unspanned`, `std/assert`.

`to toml` behaviour (probe run 2026-09-14, `nu --no-config-file -c '... | to toml'`):

- `list<record>` serializes as `[[name]]` array-of-tables; nested `record` as `[a.b.c]` headers; simple keys precede sub-tables; insertion order is kept. Round trip `to toml | from toml` preserves both.
- `null` serializes as the string `"<Nothing>"`. Strip nulls before serializing.
- `datetime` serializes as `2026-09-14T00:00:00.0+00:00`. Format with `format date %F` first; a string date serializes as `date = "2026-09-14"`.
- No inline-table output; `[ticket.reference.remote]` is the deepest header (depth 3).

`open` on a v3 file: parses (Nushell tolerates multi-line inline tables); `issue.date` arrives as `datetime`; `tasks` is a record keyed `"1"`, `"2"` (one file has `"0"`); `tasks.N` has `id`, `target`, `completed` (bool or date), `subtasks[] {synopsis, llm, done}`.

`_internal/todo` (`todo/mod.nu` at refactor/todo-prelude ffd8eb0): `main [...rest --json --ndjson --long]` L16 is the `td` passthrough (`--json` parses and, for task-shaped rows, hydrates); `list [--project --label --parent --filter --completed --since]` L30 returns `table<id content description labels project parent due priority url>`; `view [ref]` L55; `add [content --project --description --labels --parent --due --priority] -> record` L61; `edit [ref --content --description --labels --due --no-due --priority]` L82; `done [...refs]` L103; `reopen [...refs]` L108; `rm [...refs]` L113; `projects [] -> table<id name url>` L123; `labels []` L128; `find [slug --project --threshold]` L137 (returns null on a tie). Refs are an id, `id:<id>`, or exact content. Every call goes through the private `todoist` helper L157 (JSON reads via `util attempt --merge`, writes via `elevate with-auth`).

`_internal/util` (`util/mod.nu`, same commit): `contains [cell: cell-path]` L19 (accepts `?`/`!` suffixes); `timestamp` L28; `--wrapped attempt [name ...rest --check --merge]` L33; `editor [--cd --depth ...]` L55. `with-auth` is no longer here.

`_internal/elevate` (`elevate/mod.nu`, same commit): `--wrapped with-auth [name --login: closure --pattern --strict ...rest]` L50, the auth-retry wrapper for `gh` and `td`.

`_internal/completion` (`completion/mod.nu`): `into completions [options: record = {} --to-string: closure --repr: record]` L41 wraps a list or `value`/`description` table into `{options, completions}`; elements are formatted by type; strings are nuon-quoted only when a bare argument would misparse (whitespace, quotes, `( ) [ { } | ; $`, a leading dash, `true`/`false`/`null`). Import it directly (`use ../completion "into completions"`); util no longer re-exports it.

`_internal/dispatch` (`dispatch/mod.nu`): `dispatch type {<type>|<type|type>|_: <value or closure>} --pipe|--exec [--default]` matches the `describe` name of the input (`string`, `record`, `closure`, `cell-path`, `nothing`, ...) and pipes or runs the closure; `dispatch os` likewise on `$nu.os-info.name`.

Import rule: std submodules only (`use std/assert`, `use std/util [repeat structure]`, `use std-rfc/conversions "into list"`, 1 to 6 ms each); `use std <name>` and `use std-rfc <name>` load the whole root module (about 40 ms and 20 ms at login).

`_internal/repo` (`repo/mod.nu`, same commit): `$env.repo.path` is `table<name owner directory>` built by `hydrate-git-context` L229; `repo list [regex?]` L107 filters it; discovery honours `$env.repo_exclude` L258. Todoist aliases (Phase 3b) are not there yet.

`gh` 2.100.0 (`gh issue <cmd> --help`): `create -R owner/repo -t <title> -F - -l <label>` (body on stdin), prints the issue URL; `edit <n> -R owner/repo -F -` (also `--add-label`, `--remove-label`); `view <n> -R owner/repo --json number,url,state,title,body`; `list -R owner/repo --state all --json number,title,state,url --limit N`; `close <n> -R owner/repo --reason {completed|"not planned"}`; `reopen <n> -R owner/repo`. `create --recover` exists (the old module forwarded it via `...rest`); v4 does not use it.

`claude` CLI: `claude -p '<prompt>' --output-format text` (`--output-format` choices: text, json, stream-json; only with `--print`).

`td` 5.3.4: `td completed list --project <name> --since --until --json` has no parent filter; filter the `parent` column client-side. Three-month window.

Strict TOML check: `python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' <file>` (used in the audit; 8 of 9 v3 files fail it).

Old module, copy-worthy fragments only: slug discovery glob `~/.local/share/nupm/modules/issue/mod.nu:344-349`; URL to index parse `parse '{_}/issues/{index}'` at issue/mod.nu:209-213; `run-gh-with-repo` error shape at `repo/mod.nu:304-318`.

### Anti-patterns (do not do)

- Do not `use` the nupm `issue` or `tasks` modules; do not touch sqlite (`stor`, `query db`).
- Do not run `git commit`, `gh issue develop`, or any command that changes the user's branch or history.
- No `...rest` passthrough to `gh` or `td` from `dev` commands; every flag `dev` accepts is in its own signature.
- Do not export commands named `update`, `rm`, `find`, `get`, `export`: exported names are predeclared before imports parse and shadow builtins inside `util`/`todo` (see `todo/docs/2026-09-13_todo-todoist.spec.md`, "Naming"); `edit` and `list` are proven safe (`todo` and `hook` export them while importing `util`). Run ide-check on `dev/mod.nu` after adding each export.
- Do not write `null` or `datetime` values through `to toml` (see probe facts).
- Do not build a local index or cache of issues; `$env.repo.path` plus `docs/tickets/*.toml` is the whole discovery model.
- `try { }` without `catch` returns null; do not rely on it to propagate errors.
- Do not wrap a record with std-rfc `into list` (it yields a key/value table); `append []` wraps any value into a list.
- Bare column names inside a parenthesised subexpression of a `where` row condition parse as commands (`(file | path exists)` ran the external `file`); use `where {|r| (...) }` with the whole expression parenthesised.

## Sync decisions D6 to D9 (settled in chat, transcribed by the Phase 4 spec)

D1 to D5 and D10 to D15 live, rewritten by the user, in the spec's Decisions section and are authoritative. D6 to D9 below are the sync decisions settled in chat on 2026-09-17/18 (traced in `07-lifecycle.d2`); the Phase 4 spec transcribes them.

- D6 Status and closure: `draft` is skipped (no remote leg; the Todoist task is still ensured so the phone can hold rows). `open` keeps the issue open; `done` closes it with reason completed and checks the Todoist task; `aborted` closes with reason not planned and checks the task too. Closure is accepted from any surface: a checked Todoist task or a closed issue found by sync sets the file's `status` (`done` for completed/checked, `aborted` for not-planned) and propagates to the others. Reopening is accepted from Todoist only (unchecking the task sets `status = open` and reopens the issue); an issue reopened on the host while the task is checked is reported, not applied. `reference.remote.branch` is set to the slug on first create; no branch is created.
- D7 Todoist model: the ticket is one task (`content` = slug) in the project named after the repository or one of its aliases (Phase 3b); resolution order is the project named after the repo, then each alias (`project` or `project/section`); the project must exist, else the error names `td project add <repo>`. On first link sync searches every project for the slug, errors when it is found in more than one, writes `reference.todoist` and reports a task found outside the expected project. Afterwards everything is matched by `reference.todoist.id`, never by content. `[[tasks]]` rows are the task's direct subtasks, mirrored wholesale from Todoist on every sync (content, description, attribution label, completed); local edits reach Todoist only through `edit --add-task` (`todo add --parent id:<id>`) and `edit --complete` (`todo done`). The kind label is set once at creation (`%deliverable` when `[[ticket.output]]` is non-empty, else `%actionable`) and then owned by Todoist. Tasks carrying a `?` label (`?seed`, `?stub`) are skipped. A task deleted or moved out of every mapped project, or whose `content` no longer equals the slug, is reported, not repaired (`# ponytail:` names this ceiling; the upgrade is `dev sync --relink`). A `done`/`aborted` ticket with no `reference.todoist` gets no task created.
- D8 Remote projection: the issue body is `dev <slug> --md` (spec: title, outcome, requirements, constraints, output, landscape, bindings, the `## Tasks` checklist from `[[tasks]]`) and is sync-owned: hand edits are overwritten, discussion lives in comments. Version targets: `ticket.target = "<version>"` maps to the remote milestone titled `<version>` and the Todoist task `<repo>@<version>` in the parent project; sync ensures the milestone exists (creating it, state from the Todoist task's checked flag, due from its due date), assigns the issue to it, and maintains the arrow line of the version-target task's description (`→ <repo>#a #b`, the member issues) under the spec's D12 rule: replace the first line when it already is an arrow line, otherwise prepend, never touching a hand-written line. A missing version-target task is an error naming it and the flag that creates it: `dev sync <slug> --create-target` adds `<repo>@<version>` to the parent project of the repository's Todoist project (no section, no labels; the user curates those), then continues. The host is never read for rows: the checklist is write-only.
- D9 Live sync tests: no scratch remote repository or Todoist project is named, so the remote leg is verified by the user against a real issue with `--dry-run` first; the Todoist leg uses the opt-in `DEV_SYNC_WRITE=1` pattern from `todo/tests/suites/todo.nu:27` (`TODO_TEST_WRITE=1`) and cleans up with `todo rm`.

## Phase 1 — Session 4 spec: `dev` core (completed 2026-09-15, amended through 2026-09-18)

Deliverable: `dev/docs/2026-09-15_dev-core.spec.md`. Written against `04-handoff-prompt.md` on 2026-09-15, rewritten by the user the same evening (D1 to D14), reviewed (D15), then amended on 2026-09-18 after the sync design thread: intro ownership list, D1 (one-tier rows), D2 (v3 tasks dropped), D12 (description line), D13 (slug charset, `+`, no dots), `ticket.target`, `reference.remote`, the `edit` write-through bullets, provider-neutral wording. The section list below is what it contains; the spec, not this plan, is authoritative on every point.

Sections: Decisions (D1 to D5, D10 to D15), Schema (canonical key order, per-key table, the `hooks-placement` example that doubles as `dev/docs/example.toml`), Contracts (six signatures, behaviour bullets), Validation and error copy, Migration mapping (44 leaf paths, each mapped, dropped or refused), Tests (the Phase 2 and Phase 3 assertion lists), Naming, Verification.

Gate: the user re-reads the amended spec and approves before Phase 2 starts (the 2026-09-15 approval predates the amendments).

## Phase 2 — Session 4 build A: schema, `dev`, `dev list`, `dev query`, `dev edit`

Files: `_internal/dev/mod.nu` (new), `_internal/dev/tests/mod.nu` (new seam), `_internal/dev/tests/suites/dev.nu` (new).

Read first: the Phase 1 spec, Phase 0 API list, `time/tests/mod.nu` (seam to copy verbatim), `time/tests/suites/time.nu:1-9` (before/after each), `todo/tests/suites/todo.nu:14,26` (`skip`), `todo/mod.nu:1-12` (module header and imports to copy), `completion/mod.nu:41` (`into completions`).

Write tests first. `dev/tests/mod.nu` is the seam, copied from `time/tests/mod.nu` (module first, then `std/assert`, then the runner's `skip`). `dev/tests/suites/dev.nu`:

```nu
use ../mod.nu *

def "before each" []: nothing -> record<root: path> {
  let root: path = mktemp --directory --suffix=-dev
  mkdir ($root | path join docs tickets)
  {root: $root}
}
def "after each" []: record -> nothing { rm --recursive --force $in.root }

def "test list empty" []: record -> nothing {
  let t: record = $in
  $env.repo = {discovery: false cache: null path: [{name: scratch owner: me directory: $t.root}]}
  assert equal (dev list) []
}
```

One `def "test <name>"` per assertion group below, each setting `$env.repo` from `$in.root` first; the runner spawns one child interpreter per test, so tests share only the fixture. Assertions: `dev list` empty; write a v4 fixture by hand into `docs/tickets/alpha.toml`; `dev alpha` returns the record with `date` as datetime and `status` validated; `dev query alpha ticket.outcome` returns the string; `dev edit alpha --set {status: open}` returns the path and the file re-reads with `status = "open"`; `--set {target: "0.4.0"}` round-trips; `--add-task`/`--complete` on the unlinked fixture error naming `dev sync`; editing twice yields identical bytes (`open --raw` compare); a file with `version = "3.0.0"` makes `dev` error with a message containing `dev migrate`; an unknown status errors; a file named `v0.4.0.toml` errors naming `no dots` (spec D13); `python3 tomllib` parses the edited file (call via `^python3 -c ... | complete`, exit 0); a second repo with the same slug makes `dev alpha` error with `--repo`; `dev alpha --md` equals the expected Markdown.

Then implement, in this order, each as the minimum that passes:

1. Discovery: `files [] -> table<slug repo path>` from `$env.repo.path` and `glob (dir | path join docs tickets '*.toml')` (pattern at issue/mod.nu:344-349).
2. `dev [slug --repo --md]`: `open`, check `version == "4.0.0"`, validate required keys, `status`, the slug charset (D13), `into datetime` on `ticket.date`, the attribution-label check on `tasks`; `--md` renders per the spec's `--md` bullet (`to md` for tables, `## Tasks` checklist).
3. `dev list [--status --repo]`: `files | each { open | select ... }`.
4. `dev query [slug property: cell-path]`: `dev $slug | get $property`.
5. `dev edit [slug --set --add-task --complete]`: merge `--set`, rebuild in canonical order (`target` after `status`), strip nulls, `format date %F`, `to toml`, `save --force` to `mktemp --tmpdir-path <same dir>`, then `mv --force` over the original. `--add-task` and `--complete` only raise the "no Todoist task yet" error in this phase; their Todoist leg is Phase 5a.
Completers: `_slugs` from `files`, `_repos` from `$env.repo.path.name`, both through `into completions`.

Verification: `nu --no-config-file --experimental-options=all --ide-check 500 dev/mod.nu | grep -c '"message"'` is 0; `nu-lint --format=compact dev` clean; `test dev/tests/suites` reports every test `ok`; `grep -nE 'stor |query db|git |gh |\.\.\.rest' dev/mod.nu` is empty.

Guards: export names per Phase 0; no cache; no `try {}` without `catch` on the write path; the temp file lives in the target directory so `mv` is a rename, not a copy.

Scope: four analytical tasks. If `edit` grows past merge-rebuild-write, stop and split.

## Phase 3 — Session 4 build B: `dev new`, `dev migrate`

Files: extend `_internal/dev/mod.nu` and `_internal/dev/tests/suites/dev.nu`.

Read first: the spec's D2, D5, D13, D15, Migration mapping and Tests sections, Phase 0 (`claude -p`, `input`, `util editor` L55), the two v3 samples named in the spec.

Tests first: copy `hooks-placement.issue.toml` and `windows-portability-batch.issue.toml` (xabort, external notes, `extends` path) into the scratch repo; `dev migrate hooks-placement --dry-run` returns a row with `changed = true` and the file bytes are unchanged; `dev migrate hooks-placement` rewrites it, `dev hooks-placement` loads, `python3 tomllib` parses it, the file has no `tasks` key (D2), `ticket.reference.remote.index == 5`, and the file equals the spec's example byte for byte; copy `polyglot-reference-autodoc-tooling.issue.toml` and assert `dev migrate` errors naming `issue.vision.outcome`; `dev new beta --name Beta` returns a path, `dev beta` loads with `status == draft` and today's date; `dev new beta` again errors `already exists`; `dev new V0.4.0` errors naming `dev new v0-4-0`; `dev migrate --all --dry-run` lists both.

Implement:

1. `dev new [slug --name --interactive --continue --prompt --recover --files --edit]` (signature in the spec's D5): validate the slug (D13), build the v4 record from the spec's example (name defaults to the slug title-cased), `--interactive` reads `input` per header field, `--prompt` per D5, write through the same writer as `edit`, `--edit` calls `editor`. Ship `dev/docs/example.toml` (the spec's example) in this phase since `--files` defaults to it.
2. `dev migrate [...slugs --all --dry-run]`: read `docs/issues/<slug>.issue.toml`, refuse `version != "3.0.0"` and the D2 shapes with the offending path in the message, drop `tasks` (D2), map every other leaf per the spec's Migration mapping, write `docs/tickets/<slug>.toml` through the same writer, remove the source (D15), return `table<slug from to changed>` with paths.

Verification: same ide-check, nu-lint and test commands as Phase 2; additionally `for f in <scratch>/docs/tickets/*.toml` all pass `python3 tomllib`, and `<scratch>/docs/issues` holds only the refused file.

Guards: `--prompt` is not tested live (it costs a model call); test the parse-failure branch with a stub string instead. No generic shape mapper; refused shapes error.

## Phase 3b — `repo` aliases (own branch, `feat/repo-aliases` from main)

Files: `_internal/repo/mod.nu`, `_internal/repo/tests/{mod.nu,suites/repo.nu}` (new; seam copied from `todo/tests/mod.nu`), `_internal/todo/mod.nu` (`repo-name` L211 and `find` L137), `_internal/track/mod.nu:37` (the hook's `todo find $branch --project $repo` call, spec `track/docs/2026-09-13_track-hook.spec.md:51`). `repo` has no spec or tests today; this phase adds the suite, not a spec.

Read first: `repo/mod.nu:229-260` (`hydrate-git-context`, `discover-git-repos`), `todo/mod.nu:137-156` (`find`), `track/mod.nu:30-40`, Phase 0's `repo` line.

Write: a registry column `aliases: list<string>` per row, empty by default, set with `repo push <dir> --alias <project>` or `--alias <project>/<section>` (append, `uniq`); `repo list` shows it. `todo find --project` and the track hook resolve the Todoist project by trying the repo name first, then each alias in order (a `project/section` alias filters `todo list` to that section). One test per resolution step against a fake `$env.repo.path`. This is the seam `dev sync` uses for `development` (sections map to `~/.config` and `~/library/nushell/_internal`) and `nupm-registry`; no `dev` code changes here.

Verification: `test repo/tests/suites`, `test todo/tests/suites`, `test track/tests/suites` all `ok`; ide-check and nu-lint clean on the three modules. Merge to main before Phase 4; rebase `feat/dev-module` afterwards.

## Phase 4 — Session 5 spec: `dev sync`

Deliverable: `_internal/dev/docs/<today>_dev-sync.spec.md`. No code. Also replace the placeholder sentence in the core spec's intro ("has its own spec, `dev/docs/<date>_dev-sync.spec.md` ... not written yet") with the real path.

Read first: the core spec (intro ownership list, schema incl. `target`, `reference` block, D1 rows, D2, D12 description line, D13 slugs, the `edit` write-through bullets), Phase 0 (`gh`, `td`, `todo`, `elevate with-auth` L50), D6 to D9 above, `06-ownership.d2` and `07-lifecycle.d2` (stages s1 to s6 and breakdowns W1 to W5: renamed task, pruned task, closed on the host first, half a sync, version target renamed or released early), `todo/mod.nu:137-186` (`find` and the `todoist` helper), `repo/mod.nu:304-318` (gh error shape), the Phase 3b alias resolution.

Write: the contract `dev sync [...slugs --all --dry-run --create-target --skip: list<string> = []] -> table<slug todoist remote milestone result>`; the algorithm as ordered "ensure" steps per leg so re-running is a no-op:

- Todoist leg (D7): resolve the project (repo name, then aliases); link by `reference.todoist.id` or, unlinked, search every project for the slug (error on more than one, report wrong placement); ensure the ticket task exists (`todo add <slug> --project --labels [%kind]`, kind per D1; skipped for `done`/`aborted` tickets without a reference); ensure the description's first line is the D12 link when `reference.remote` is set; mirror the subtasks into `[[tasks]]` (`todo list --parent id:<id>`, plus `todo list --completed --parent` within the three-month window); apply closure/reopen per D6; write `reference.todoist`.
- Remote issue leg (D6, D8): skipped for `draft`; render the body; ensure the issue exists with title = slug (`gh issue create -R -t -F -`), body equal (`gh issue edit -F -`), state per D6 (`gh issue close --reason`, `gh issue reopen`); write `reference.remote`.
- Milestone leg (D8): only when `ticket.target` is set; find the `<repo>@<version>` task in the parent project (error naming it and `--create-target` when missing; with the flag, create it there); ensure the milestone `<version>` exists (`gh api repos/{owner}/{repo}/milestones`, create when missing, state and due from the task); assign the issue (`gh issue edit --milestone`); maintain the arrow line of the version-target task's description (`todo edit id:<id> --description`, D12 replace-or-prepend) from the milestone's member issues.

Also: the dry-run row format (what would change per leg); error copy naming next commands; `--skip` accepting `todoist`, `remote` and `milestone`; auth retry through `elevate with-auth` once per leg; the report-only cases (task deleted, content drifted from slug, issue reopened while the task is checked, version-target task missing) as rows in the result, never repairs; which remote reads happen and their cost; tests split into offline (body rendering from a fixture, diff computation from fake remote rows, the closure/reopen decision table from D6 as a pure function over `(status, task checked, issue state)`) and opt-in live (`DEV_SYNC_WRITE=1`). Confirm `gh api` milestone endpoints against `gh api --help` in that session; Phase 0 did not probe them.

Verification: every "ensure" step names the exact `todo`/`gh` call from Phase 0 or its own probe; the idempotence argument is written per step; every W breakdown in `07-lifecycle.d2` maps to a result row or an error message; the words "GitHub" and "forge" appear only where `gh` is named as the wired CLI (the design is provider-neutral: "the remote host"); user approves before Phase 5.

## Phase 5a — Session 5 build: Todoist leg and `edit` write-through

Files: extend `_internal/dev/mod.nu` and `_internal/dev/tests/suites/dev.nu`.

Read first: Phase 4 spec (Todoist leg, D6 decision table, D7), Phase 0 API list, `todo/mod.nu:157-186` (`todoist` helper), `todo/tests/suites/todo.nu:27` (`TODO_TEST_WRITE` gate).

Tests first: offline: the D6 decision table as a pure function; the row-diff function given fake `todo list` rows produces the `[[tasks]]` mirror and the closure/reopen action; `dev sync alpha --dry-run --skip [remote milestone]` with no Todoist project errors naming `td project add`; `dev edit alpha --add-task` on a fixture with a fake `reference.todoist` calls the write path (assert through the dry-run row, not a live call). Opt-in live (`DEV_SYNC_WRITE=1`): sync a scratch ticket into a scratch Todoist project twice, assert the second run reports no changes, `edit --add-task` then `edit --complete` round-trip through Todoist, then `todo rm` the created tasks.

Implement the Todoist leg as a private function called from `sync`, all `td` traffic through the `todo` module (never `^td` directly); `edit --add-task`/`--complete` gain their Todoist calls here. Write `reference.todoist` back through the `edit` writer.

Verification: ide-check 0; nu-lint clean; `test dev/tests/suites` reports every test `ok`; `grep -nE 'git commit|gh issue develop|--recover|mktemp.*md|\^td' dev/mod.nu` empty; `dev sync --all --dry-run --skip [remote milestone]` run twice by the user shows the same output both times.

Guards: no resume files; no auto-commit; never print `td` tokens; the mirror is written only after the remote calls succeed.

## Phase 5b — Session 6 build: remote issue and milestone legs

Files: extend `_internal/dev/mod.nu` and `_internal/dev/tests/suites/dev.nu`.

Read first: Phase 4 spec (remote and milestone legs, D8), Phase 0 (`gh`, `elevate with-auth` L50), `repo/mod.nu:304-318`, `issue/mod.nu:209-213` (URL to index parse), Phase 5a's leg as the pattern to copy.

Tests first: offline: `dev alpha --md` body equals the expected string; the milestone decision (create/assign/state) from fake `gh api` rows; `--skip [todoist]` runs the remote legs alone. Live: verified by the user with `--dry-run` against a real issue first, then one real sync on a ticket they choose (no scratch remote repository).

Implement the two legs as private functions, every `gh` call through one private wrapper using `with-auth --login {|| ^gh auth login } gh ...` that errors with stderr. Write `reference.remote` back through the `edit` writer after the issue leg succeeds; the milestone leg writes nothing to the file.

Verification: ide-check 0; nu-lint clean; `test dev/tests/suites` all `ok`; the Phase 5a grep plus `\^gh` empty outside the wrapper; `dev sync --all --dry-run` run twice by the user against real repos shows the same output both times.

Guards: as 5a; never print `gh` tokens; `reference.remote` is written per leg with the skip recorded in the result row (the Phase 4 spec fixes the row shape).

## Phase 6 — Verification and cutover

1. Rename the one dotted slug on every surface first: `v0.4.0-close-out` becomes `pre-version-ship-review` (the v3 file and its `issue.slug`, the Todoist task content, the nu-fluency issue #8 title; slugs name the work, not a version, spec D13) so migrate and the first link pass D13. Then `dev migrate --all --dry-run`, hand-edit the two D2 files, `dev migrate --all`; then `for f in ~/code/*/docs/tickets/*.toml` all pass `python3 tomllib` and `~/code/*/docs/issues/` is empty.
2. `dev list` shows all 14 tickets with `version` 4.0.0 (add `version` to the list output only if this check needs it; otherwise `dev query <slug> version`).
3. `dev sync --all --dry-run` twice, identical output; then a real `dev sync` on one ticket chosen by the user.
4. Grep guards across `dev/mod.nu`: `stor `, `query db`, `git commit`, `gh issue develop`, `...rest`, `<Nothing>` all absent.
5. Cutover: the user removes the nupm `issue` and `tasks` modules and any `use issue`/`use tasks` lines in `~/.config/nushell`; `dev/docs/_design/` stays as the tracked design record (audit, plan, diagrams).
6. Commits: one per phase on `feat/dev-module`; push only when asked.
