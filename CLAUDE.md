# nu-lib

A personal library of Nushell modules for a development environment. Each top-level directory is one module
(`<name>/mod.nu`, sometimes with submodules such as `util/workspace/` or `completion/external/`). The root `mod.nu` is a
barrel that re-exports the commonly used modules.

## Nushell version policy

The library always targets the **latest Nushell nightly**. There is no version pinning: when a nightly changes
behavior and a module breaks, the module is defective and gets fixed for the current nightly — never guarded by
version checks. Check `nu --version` before assuming a language behavior; verify semantics empirically
(`nu --no-config-file -c '…'`) rather than from memory, since nightly semantics drift.

## Module resolution

- Modules import each other by bare name (`use completion "into completions"`, `use validate rules`). This only
  works when the **repository root is on `NU_LIB_DIRS`**. Run code against a checkout with
  `nu --no-config-file -I <checkout-root> -c 'use <module>; …'`.
- In a git worktree, pass the *worktree* root with `-I`. The owner's shell config puts the main checkout on
  `NU_LIB_DIRS`, so without `-I` a worktree's modules silently resolve their imports from the main checkout.
- `export use <module>` (as in the root barrel) does **not** run the re-exported module's `export-env` block; only a
  direct `use` does. Environment set-up must therefore be triggered explicitly: `loaders.nu` runs only the env
  blocks with guarded `source-env (… <module> mod.nu)` calls. `source-env` of a file also executes its top-level
  `use` statements (running those modules' env blocks), so a file meant for `source-env` must import nothing.
- Every module parses with only the repository on the include path; nothing outside it is imported at parse time.
  Machine-specific values come from configuration (see `_docs/module-partition.md`), not from code.
- Mixed modules are split: `<module>/local/mod.nu` re-exports the abstract part and adds the configuration-dependent
  commands (`alarm`, `completion`, `mods`). `completion/external` is a deprecated shim for `completion/local`. The
  root barrel exposes them as bare names and nothing exposes `local …`-prefixed forms; `init-local` writes the
  autoload file that loads the barrel (see `_docs/module-partition.md`).

## Module partition

Modules are either **abstract** (pure Nushell, usable on any machine) or **configuration-dependent** (need
installed programs, a particular OS/host, environment variables, or the owner's Nushell config).
`_docs/module-partition.md` holds the classification and its consequences; keep it current when adding a module
or a new external dependency.

## Conventions

- Section banners: `# ——— name ———…` padded to column 80, in the order imports, constants, types, helpers,
  definitions/commands, environment, completions.
- Every exported command has a one-line description comment, typed parameters with doc comments, and an explicit
  input/output signature. `@category` attributes group commands for `help`.
- Cell paths are written with the `$.` prefix (`get $.name`, `insert $.role …`). The `!` suffix means
  case-insensitive access and `?` means optional.
- Errors with stable identities use `error raise --code=<module>::<context>::<kind>` from the `error` module.
- Lint with `nu-lint <file>` (owner config at `~/.config/nu-lint.toml`); file- or line-level suppressions use
  `# nu-lint-ignore-file: <rule>` / `# nu-lint-ignore: <rule>`.
- Format with `topiary`. It refuses files that contain `type` declarations: comment the typedefs out before
  formatting and restore them afterwards.
- Comments and docs must describe actual behavior. When behavior changes, update the doc comment in the same change.

## Data shaping and performance

- No `mut`. Build values from immutable `let` bindings and pipelines; closures cannot capture `mut` variables
  anyway, so this keeps every loop movable into `each`/`par-each`.
- Don't build lists or records inside `reduce --fold`: every step copies the accumulator, so it is quadratic (orders
  of magnitude slower at a few thousand items). Use `reduce` only to fold to a scalar, and prefer a builtin
  (`math sum`, `str join`) when one exists.
- Lists: `each --flatten` when each iteration yields a list (same cost as `each | flatten`, reads better).
- Records:
  - `items {|k v| …}` for per-entry work: iterating a record, or mapping/filtering it into a new record by returning
    `[key value]` pairs or single-key records `{$k: $v}` (null to drop, then `compact`) and finishing with
    `into record`. It is the fastest option; the two return shapes cost the same and both let later duplicate keys
    win, so pick whichever reads better (pairs additionally reject anything that isn't exactly two items).
  - `transpose k v` when the entries need table verbs (`where`, `sort-by`, `group-by`, multi-step `update`), then
    `transpose --header-row --as-record` back. Clearer for multi-step reshaping, roughly 2–7× slower than `items`.
  - `into record` turns a list of `[key value]` pairs into a record. Given a table it *merges the rows* (union of
    columns, later rows win), which exists so a single-row table such as `"k=v" | parse "{key}={value}"` becomes a
    record; it is not a key/value conversion for `[[k v]; …]` tables.
  - `rotate` is a matrix rotation for tables: on a record it puts values before keys (`rotate key value` labels
    them backwards) and `--ccw` reverses the order. Use `transpose` for records.
- `each` doubles as "apply if present": piped a scalar or record it runs the closure once and returns the bare result;
  piped `null` it skips the closure. Only use it that way where the value can never be a list (a list is iterated).
- `each` by default; `par-each` costs ~1 ms per call before any work, so it only pays off when each item does slow
  work (I/O, an external program, heavy computation) and there are many items. Never use it for writes to shared
  state (`std-rfc/kv`/SQLite, files, `$env`): parallel kv writes contend on SQLite's lock and race.
- Batch persistent state: every `kv get`/`kv set --universal` opens SQLite (~0.5 ms). Data that is read or written as
  a whole (a registry, a cache) belongs in one value, not one key per row.
- `describe` walks the whole value; type dispatch with `match ($in | describe)` is free on scalars and records but
  scales with list/table size — use `first | describe` when only the element shape matters.
- Hook bodies (`pre_execution`, `pre_prompt`, `env_change`) run on every command or `cd`: read `$env`, not storage,
  and avoid spawning external programs there.
- Measure before arguing about speed: `timeit { … }` for one run, `use std/bench; bench {…} {…} -n 10` for mean
  and spread across alternatives. `_docs/data-shaping.md` records measurements.

## Testing

- The `test` module is the runner (`_docs/testing.md`). Suites live in `_tests/suites/<module>.nu` (submodules are
  covered in their parent's suite); fixtures in `_tests/fixtures/<module>/`; `_tests/mod.nu` is the shared seam.
- A suite imports the module(s) it tests **before** the seam (`use validate` then `use ../mod.nu *`): the runner's
  `skip` otherwise shadows the builtin `skip` inside modules parsed after it.
- The repository's `nutest.nuon` lists the suite `paths`, puts the repository root on the children's include path,
  and sandboxes every test child (throwaway HOME/XDG). Run `nu --no-config-file -I <checkout> -c 'use test; test'`
  from the checkout root.
- `test` returns a table; `test --strict` raises on any failure. Results report `skip` for unavailable dependencies,
  never `ok`.
- After changing `test/mod.nu`, run its framework-free self-test: `nu --no-config-file _tests/selftest.nu`.

## Running module code safely

Many modules have side effects at import time (`export-env`) or persist state:

- `std-rfc/kv` with `--universal` writes SQLite under `$nu.data-dir`; point `XDG_DATA_HOME` at a temp dir **and
  create `$XDG_DATA_HOME/nushell` first** (kv does not create it), or set `NU_UNIVERSAL_KV_PATH`.
- `proj` scans `$env.WORK` on import (skipped when `WORK` is unset). Point `WORK` at a temp dir.
- The owner's interactive environment exports variables that change module behavior (`mods_home`, `ZELLIJ`,
  `NUPM_HOME`, `EDITOR`, `WORK`). For hermetic runs, start children from a scrubbed environment.
- Never exercise privileged or destructive paths for real (`elevate`, `mount`, `link`, `pman` install/upgrade,
  `reload`, `ipex-llm-ollama serve`); stub the external (`sudo`, `reset`, package managers) with a script on `PATH`.

## Documentation layout

- `_docs/` — durable, repository-wide documentation (committed).
- `<module>/docs/` — per-module specs and design records (dated filenames).
- `_runbook/` — scratch notes for a single working session; git-ignored, never referenced from committed files.
