# 01 — Evidence

Gathered inline by the orchestrator (no subagents: the CLAUDE.md persona gate requires user confirmation per spawn). Every item cites a file:line, a command, or a measured value.

## E1 Structural — schema shape across the 9 files

Measured with a Nushell walk over `open <file>` (leaf path, depth):

| file | maxdepth | leaves | `tasks` keys | `vision.outcome` | `landscape.external` |
|---|---|---|---|---|---|
| audit-pipeline-refinements | 5 | 35 | 1 | string | null |
| inspect-shape-refinements | 5 | 52 | 1,2 | string | null |
| v0-4-0-close-out | 5 | 48 | 1 | string | null |
| issue-status-backfill | 5 | 31 | 1 | string | null |
| madr-adoption | 5 | 29 | 1 | string | null |
| skills-residual-sweep | 5 | 46 | 1 | string | null |
| hooks-placement | 5 | 29 | 1 | string | null |
| nu-over-bash-hooks | 6 | 35 | 1,2 | string | record (ad hoc keys) |
| polyglot-reference-autodoc-tooling | 7 | 88 | 0,1,2 | record `{mode, threads[]}` | record (ad hoc keys) |

- 52 distinct leaf paths across 9 files. Shape drift on the same key: `issue.vision.output` is a table in some files (`output.alias/path/purpose`) and an array of tables in others (`output[].path/purpose`); `issue.vision.outcome` is a string in 8 files and a record in 1; `issue.vision.landscape.external` is null in 7 and a free-form record in 2; `issue.extends` appears in 1 file only.
- Task keys are numbered table names (`[tasks.1]`, `[tasks.2]`); one file starts at 0, the rest at 1. Order is by key name, not by position, so renumbering is required to reorder.
- Nesting: 5–7 levels (`issue.vision.landscape.external.existing-implementations.candidate-options[].assessment`).
- v3 table order in `hooks-placement.issue.toml`: `[issue]`, `[issue.vision]`, `[[issue.vision.output]]`, `[issue.vision.criteria]`, `[[issue.vision.scope.excluded]]`, `[issue.bindings]`, `[[issue.bindings.xvalue]]`, `[issue.reference]`, `[issue.vision.landscape]`, `[tasks]`, `[tasks.1]` — `[issue.vision.landscape]` is written after `[issue.reference]`, so the vision subtree is split across the file.

## E2 Portability — strict TOML

`python3 -c 'import tomllib; tomllib.load(...)'` on all 9 files: 8 fail, 1 passes. Failure: "Invalid initial character for a key part" at an inline-table array spanning lines (e.g. `audit-pipeline-refinements.issue.toml:36-39`, `excluded = [ { item = '...',`). TOML 1.0 forbids newlines inside inline tables; Nushell's `open` accepts them, so the files only round-trip through Nushell.

## E3 Copy & honesty — `issue` module (`~/.local/share/nupm/modules/issue/mod.nu`)

- L202: on push failure prints `to attempt a retry, pass --resume="<path>" with --recover=<string>`. `--recover` is a `gh issue create` flag that reaches `gh` through the `...rest` passthrough (L168); it is real but absent from the module's own help and meaningless with `--existing` (edit has no such flag). Corrected during make-plan Phase 0 (`gh issue create --help`).
- L229: `rm --force $path` in the `finally` block deletes the resume file that L202 just told the user to pass back.
- L355 `V2_PROPERTIES` and L395: the `--property` completer for `query` lists v2 cell paths against a v3 schema.
- L350, L376: completers take a `context: string` positional (deprecated completer form).
- L86: help text typo "their are".
- L248: error `all flags are mandatory` names no flag.
- L4, L8: `RAMDA_DOC_ROOT_DIR` / `ISSUES_DIR` env overrides, undocumented in help.
- 12 `error make` strings total (L18, 29, 34, 45, 102, 145, 149, 187, 203, 223, 248, and one at 112 with an empty message).

## E4 Copy & honesty — `tasks` module (`~/.local/share/nupm/modules/tasks/mod.nu`)

- L1 description: "Track issues and subtasks in a sqlite store, with TOML issue files as the source of truth." The module keeps a sqlite mirror with 30 `stor`/`query db` call sites; `dump` alone has 28, `load` 9. Two stores, one claimed.
- L9–11: "imports from other versions proceed with a warning" — schema version is not enforced (`SCHEMA_VERSION = '3.0.0'`, importer at L411–467).
- L697: `tasks` runs `git commit` on the user's repo (`warning --short "git commit failed for ($path)"`); `undo` (L219–260, 8 git calls) then has to find "sync commits" and refuses when "non-sync commits" follow (L243–247).
- 17 `error make` strings; the good ones name the next command (`relink it with tasks retarget`, L763/766); the bad one is the auto-commit path that only warns.

## E5 Surface size

- `issue`: 6 exports (`main fetch query edit list push`), 7 `gh`/`git` call sites.
- `tasks`: 12 exports (`list add import retarget edit del undo sub main meta load dump`), 23 `git` call sites, 30 db call sites.
- Three ways to load one file: `issue main <slug>`, `issue fetch`, `tasks load`. Two `list` commands.

## E6 Weight & friction

- Cold import (`nu --no-config-file -c 'use <mod>'`, median of 5): `issue` 19.45 ms, `tasks` 26.44 ms.
- Per invocation: `issue fetch` = 2 `gh` calls; `tasks dump` = 28 db statements; `tasks undo` = 8 `git` calls.
- Data duplicated on disk: every task exists in the TOML file and in the sqlite store.

## E7 States

- Empty: `no issues matched the query` (issue:149) — present.
- Error: present throughout (E3, E4).
- Failure recovery: `--resume` path is unusable (E3 L202/L229).
- Dry run: none on `issue push`; none on `tasks dump`.
- Success: `push` and `dump` return nothing distinctive (no verified success output; not exercised live).

## Known gaps

- Write paths (`issue push`, `tasks dump`, `tasks undo`) were read, not executed; the L202/L229 finding is from control flow, not a live failure.
- Visual and accessibility evidence do not apply (CLI + file format).
- No subagents deployed; all evidence collected by the orchestrator.
