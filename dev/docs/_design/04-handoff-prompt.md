# 04 — Handoff

> Superseded in part by `dev/docs/2026-09-15_dev-core.spec.md` (2026-09-15): the object is a `ticket` (`docs/tickets/<slug>.toml`, key `[ticket]`), tasks are not migrated (D2), `landscape.group` is gone (D10), `extends` holds slugs (D13), `dev migrate` moves files (D15). Read the spec's Decisions section before this file.

````
/make-plan Redesign the nushell issue tooling as `_internal/dev` (nushell-dev). Current design (`issue` + `tasks` nupm modules over the v3 `*.issue.toml` schema) failed audit at 8/30 with critical gaps in principles 6 (honest, 0), 10 (as little design as possible, 0), and 1–5,7–9 (all 1).

Verdict paragraph (quoted from 03-verdict.md):
> REDESIGN. Total 8/30, with principle 6 (honest) and principle 10 (as little design as possible) at 0; the module claims one source of truth while running two, and most of its surface exists to service the second one.

Why redesign and not refine: principle 6 scored 0 (the module's description claims "TOML issue files as the source of truth" while keeping a sqlite mirror with 30 db call sites, and its push-failure message directs the user to a retry path whose resume file the `finally` block deletes); the failures are structural, not cosmetic.

Preserve from current design:
- The `[issue]` header fields `name`, `slug`, `date`, `status` and top-level `version`, present in all 9 shipped files (E1).
- `[issue.reference]` as the tool-owned block holding remote identity (v3: `index`, `url`, `branch`).
- File naming and location: `<repo>/docs/issues/<slug>.issue.toml`.
- `issue edit`'s rewrite-in-canonical-order intent (issue/mod.nu:91, comment: comments not preserved, `tombi format` if installed).
- Error messages that name the next command, as `tasks` does at tasks/mod.nu:763/766.

Discard:
- The sqlite mirror and the six commands that service it (`import load dump retarget undo meta`). Evidence: tasks/mod.nu:1, 30 `stor`/`query db` call sites. Caused failure on principles 6 and 10.
- Numbered task tables `[tasks.N]` (order by key name; files start at 0 or 1). Evidence: E1. Caused failure on principles 3 and 7.
- The `vision.*` subtree at depth 5–7 and inline-table arrays spanning lines (8 of 9 files fail TOML 1.0). Evidence: E1, E2. Caused failure on principles 3 and 7.
- Automatic `git commit` by the tool and the `undo` machinery built on "sync commits". Evidence: tasks/mod.nu:697, :243–247. Caused failure on principle 5.
- The `--resume` failure path (resume file deleted in `finally`). Evidence: issue/mod.nu:202, :229. Caused failure on principles 6 and 8.
- `V2_PROPERTIES` completions and `context: string` completers. Evidence: issue/mod.nu:350, :355, :376, :395. Caused failure on principle 6.

Top 5 moves from the audit (verbatim):
1. #6 honest — one source of truth. Delete the sqlite mirror. `dev` reads and writes the TOML file directly; remote identity lives only in `[issue.reference]` (`github {index url branch}`, `todoist {id url}`), owned by the tool. Evidence: tasks/mod.nu:1 vs 30 `stor`/`query db` call sites.
2. #10 as little design as possible — collapse the surface. 18 exported commands become 7: `dev` (load), `dev list`, `dev query`, `dev edit`, `dev new`, `dev migrate`, `dev sync`. Evidence: E5, three load paths and two `list`s.
3. #7 long-lasting / #3 aesthetic — v4 flat, strict schema. Depth ≤ 3; arrays of tables (`[[issue.output]]`, `[[issue.scope.excluded]]`, `[[issue.landscape]]`, `[[issue.bindings]]`, `[[tasks]]`) for deterministic order; TOML 1.0 valid; one shape per key. Evidence: E1 depth 5–7 and `tasks.0`/`tasks.1`; E2 8/9 files fail strict parse.
4. #8 thorough / #6 honest — idempotent sync, no resume files, no auto-commit. `sync` converges keyed by slug and is safe to re-run; `--dry-run` on `sync` and `migrate`; the tool never commits to the user's repo. Evidence: issue/mod.nu:202, :229; tasks/mod.nu:697.
5. #4 understandable — every message names a real next step. No dead flags, no stale completers; errors name the command to run. Evidence: issue/mod.nu:202 (recovery hint pointing at a file that :229 deletes), :248 (`all flags are mandatory`), :355/:395 (`V2_PROPERTIES`).

Redesign principles in priority order:
1. #6 honest — the file is the only local store; every flag in a message exists; `[issue.reference]` is the only place remote ids live.
2. #10 as little design as possible — seven commands, one file per issue, no cache, no mirror, no history rewriting.
3. #4 understandable — a first-time user can name what `dev`, `dev new`, `dev sync` do from `--help` alone.

Decisions already made (do not re-litigate; build to these):
- Module: `_internal/dev/mod.nu`, Nushell 0.115.2; spec at `_internal/dev/docs/<date>_<topic>.spec.md`; tests as nupm `test` suites: `_internal/dev/tests/mod.nu` (seam copied from `time/tests/mod.nu`) plus `_internal/dev/tests/suites/dev.nu`, run with `test dev/tests/suites`. Static checks: `nu --no-config-file --experimental-options=all --ide-check 500 <file>` and `nu-lint --format=compact` must be clean.
- Dependencies: `_internal/todo` (Todoist via `td` 5.3.4: `todo list/add/edit/done/reopen/find/projects`), `gh` CLI, `_internal/util with-auth` for the login retry cascade. No sqlite, no nupm `issue`/`tasks` imports.
- v4 schema (`version = "4.0.0"`), TOML 1.0 valid, depth ≤ 3:
  - `[issue]`: `name`, `slug`, `date` (accept any form `into datetime` parses; write back `YYYY-MM-DD`), `status` in `draft|open|done|aborted`, `outcome` (string), `requirements` (list<string>), `constraints` (list<string>), optional `extends` (list<string> of slugs).
  - `[[issue.output]]`: `path`, `purpose`, optional `alias`.
  - `[[issue.scope.excluded]]`: `item`, optional `deferred` (string slug or bool).
  - `[[issue.landscape]]`: `scope` in `internal|external`, `group` (string), `reference`, `synopsis`, optional `type`, optional `incompatibility`.
  - `[[issue.bindings]]`: `kind` (string, replaces the `xvalue` table name), `item`, `type`.
  - `[issue.reference]` (tool-owned, never hand-edited): `github = {index, url, branch}`, `todoist = {id, url}`; absent until first sync.
  - `[[tasks]]`: `content`, `description`, `labels` (list<string>), `completed` (bool). Tasks are pointers to Todoist tasks; nothing else is stored locally.
- `dev` contracts:
  - `dev [slug: string@_slugs --md]: nothing -> record` loads and validates; `--md` renders the GitHub body.
  - `dev list [--status: string --repo: string]: nothing -> table<slug name status date repo>`.
  - `dev query [slug property: cell-path]: nothing -> any`.
  - `dev edit [slug --set: record --add-task: record --complete: list<string>]: nothing -> path` rewrites in canonical table order, temp file then rename.
  - `dev new [slug --name -n --interactive -i --prompt -p: string --edit -e]: nothing -> path` scaffolds a v4 file; `--prompt` drafts via `claude -p`; `--interactive` asks per field.
  - `dev migrate [...slugs --all --dry-run]: nothing -> table<slug from to changed>` converts v3 to v4 in place (flatten `vision.*`, renumber `tasks.N` to `[[tasks]]` in key order, `bindings.xvalue` to `[[issue.bindings]]` with `kind = "xvalue"`).
  - `dev sync [...slugs --all --dry-run --skip: list<string> = []]: nothing -> table<slug todoist github result>` tri-sync Local >> Todoist >> GitHub: local file wins on content; `completed` merges as OR; remote ids written to `[issue.reference]`; idempotent convergence keyed by slug is the atomicity model (re-running after a partial failure finishes the job); `--skip` names legs to omit (`todoist`, `github`); remote auth errors retry once through `with-auth`.
- Issue file discovery: repos registered in `$env.repo.path` (the `_internal/repo` module); each repo's `docs/issues/*.issue.toml`. No separate local index.
- Scope split (mandatory, CLAUDE.md reject-monolithic-scopes): session 4 = v4 schema + `dev`, `list`, `query`, `edit`, `new`, `migrate` (spec first, then build); session 5 = `dev sync` (spec first, then build). Each session: spec, tests, module, static checks, lint.

Deliverables for the plan:
- New information architecture: the v4 file layout in canonical table order and the seven-command tree.
- New primary flow, side by side with current: `dev new` → edit → `dev sync` versus `issue push` → `tasks import` → `tasks dump`.
- States checklist per command: empty (no issues / no tasks), error (invalid file, missing repo, remote failure), success output, dry run.
- Migration path: `dev migrate --all --dry-run` then `dev migrate --all` over the 9 shipped files; `todo` labels created on first sync; nupm `issue`/`tasks` left installed until cutover.
- Cutover criteria: all 9 files at `version = "4.0.0"` and parse under `python3 tomllib`; `dev sync --all --dry-run` reports no diffs twice in a row; nupm `issue`/`tasks` removed.

Anti-patterns to guard against (specific to REDESIGN):
- Porting old structure under new styling (a "cache" that is the mirror renamed).
- Keeping both designs behind a flag indefinitely (the migrate command is the only bridge).
- Redesigning to follow a trend rather than the principles above.
- Treating the Preserve list as optional.
- Speculative extensibility: no fields, flags or commands beyond the contracts above.
````
