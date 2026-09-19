# 03 — Verdict

**REDESIGN.** Total 8/30, with principle 6 (honest) and principle 10 (as little design as possible) at 0; the module claims one source of truth while running two, and most of its surface exists to service the second one.

Why not REFINE: the failures are structural (the sqlite mirror, numbered task tables, a TOML dialect only Nushell reads), not cosmetic. Sunk cost in 1259 lines is not a design principle.

## Highest-leverage moves

1. **#6 honest — one source of truth.** Delete the sqlite mirror. `dev` reads and writes the TOML file directly; remote identity lives only in `[issue.reference]` (`github {index url branch}`, `todoist {id url}`), owned by the tool. Evidence: tasks/mod.nu:1 vs 30 `stor`/`query db` call sites.
2. **#10 as little design as possible — collapse the surface.** 18 exported commands become 7: `dev` (load), `dev list`, `dev query`, `dev edit`, `dev new`, `dev migrate`, `dev sync`. Evidence: E5, three load paths and two `list`s.
3. **#7 long-lasting / #3 aesthetic — v4 flat, strict schema.** Depth ≤ 3; arrays of tables (`[[issue.output]]`, `[[issue.scope.excluded]]`, `[[issue.landscape]]`, `[[issue.bindings]]`, `[[tasks]]`) for deterministic order; TOML 1.0 valid; one shape per key. Evidence: E1 depth 5–7 and `tasks.0`/`tasks.1`; E2 8/9 files fail strict parse.
4. **#8 thorough / #6 honest — idempotent sync, no resume files, no auto-commit.** `sync` converges keyed by slug and is safe to re-run; `--dry-run` on `sync` and `migrate`; the tool never commits to the user's repo. Evidence: issue/mod.nu:202, :229; tasks/mod.nu:697.
5. **#4 understandable — every message names a real next step.** No dead flags, no stale completers; errors name the command to run. Evidence: issue/mod.nu:202 (recovery hint pointing at a file that :229 deletes), :248 (`all flags are mandatory`), :355/:395 (`V2_PROPERTIES`).
