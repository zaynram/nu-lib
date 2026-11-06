# nu-lib

A personal library of Nushell modules for a development environment. Each top-level directory is one module
(`<name>/mod.nu`, sometimes with submodules such as `util/workspace/` or `work/ticket/`). The root `mod.nu` is a
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
  direct `use` does. Environment set-up must therefore be triggered explicitly (e.g. `export-env { use <module> }`).
- Some modules depend on things outside the repository (see `_docs/module-partition.md`), e.g. `pman` needs the
  nupm module `nightly-toolkit`, and `conf/machine.nu` sources an absolute path on the owner's host.

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
    `[key value]` pairs (null to drop, then `compact`) and finishing with `into record`. It is the fastest option.
  - `transpose k v` when the entries need table verbs (`where`, `sort-by`, `group-by`, multi-step `update`), then
    `transpose --header-row --as-record` back. Clearer for multi-step reshaping, roughly 2–7× slower than `items`.
  - `into record` takes a list of `[key value]` pairs; given a table it returns the table's *last row*.
  - `rotate` is a matrix rotation for tables: on a record it puts values before keys (`rotate key value` labels
    them backwards) and `--ccw` reverses the order. Use `transpose` for records.
- Measure before arguing about speed: `timeit { … }` for one run, `use std/bench; bench {…} {…} -n 10` for mean
  and spread across alternatives. `_docs/data-shaping.md` records measurements.

## Testing

- The `test` module is the runner (`_docs/testing.md`). The repository's `nutest.nuon` lists the suite `paths` and
  puts the repository root on the children's include path, so run `nu --no-config-file -I <checkout> -c 'use test; test'`
  from the checkout root.
- `test` returns a table; `test --strict` raises on any failure. Results report `skip` for unavailable dependencies,
  never `ok`.
- After changing `test/mod.nu`, run its framework-free self-test: `nu --no-config-file _tests/selftest.nu`.

## Running module code safely

Many modules have side effects at import time (`export-env`) or persist state:

- `std-rfc/kv` with `--universal` writes SQLite under `$nu.data-dir`; point `XDG_DATA_HOME` at a temp dir **and
  create `$XDG_DATA_HOME/nushell` first** (kv does not create it), or set `NU_UNIVERSAL_KV_PATH`.
- `proj` scans `$env.WORK` on import; `work` creates `docs/tickets` in every registered repo when reading tickets.
  Point `WORK` at a temp dir.
- The owner's interactive environment exports variables that change module behavior (`mods_home`, `ZELLIJ`,
  `NUPM_HOME`, `EDITOR`, `WORK`). For hermetic runs, start children from a scrubbed environment.
- Never exercise privileged or destructive paths for real (`elevate`, `mount`, `link`, `pman` install/upgrade,
  `reload`, `ipex-llm-ollama serve`); stub the external (`sudo`, `reset`, package managers) with a script on `PATH`.

## Documentation layout

- `_docs/` — durable, repository-wide documentation (committed).
- `<module>/docs/` — per-module specs and design records (dated filenames).
- `_runbook/` — scratch notes for a single working session; git-ignored, never referenced from committed files.
