# 00 — Scope

Audited: the design that the new `dev` module replaces.

- v3 `*.issue.toml` schema, as shipped in 9 files: `~/code/nu-fluency/docs/issues/*.issue.toml` (8) and `~/code/ramda-doc/docs/issues/polyglot-reference-autodoc-tooling.issue.toml` (1).
- `issue` nupm module: `~/.local/share/nupm/modules/issue/mod.nu` (397 lines, 6 `export def`).
- `tasks` nupm module: `~/.local/share/nupm/modules/tasks/mod.nu` (862 lines, 12 `export def`).

Primary user: ramda, and LLM agents (claude-mem / nu-fluency workflows) that author and update issue files on ramda's behalf.

Primary task: write an issue file for a unit of work, keep it in sync with the GitHub issue and the Todoist tasks that track it, and mark tasks done.

Constraints for the replacement: Nushell 0.115 module at `_internal/dev`; `td` (Todoist) and `gh` CLIs; source-of-truth order Local >> Todoist >> GitHub; the existing `_internal/todo` module for Todoist access; docs convention `_internal/<module>/docs/<date>_<topic>.spec.md`; tests convention `_internal/<module>/tests/<module>.nu`; ponytail (minimum code).

Reference designs: none named. Peer patterns considered for principle 1: git-issue, tissue, GitHub's own `gh issue`.

Input materials: source of both modules, all 9 issue files, cold-start import timings (`nu -c 'use issue'`, median of 5), a strict TOML 1.0 parse (`python3 tomllib`) and Nushell's `open` on every file.

Not audited: the `time`, `todo`, `track` modules built earlier this thread (they are inputs, not the surface), and the `hooks-placement` workflow content inside the issue files.
