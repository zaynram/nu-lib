# Testing with the `test` runner

`test/mod.nu` is a data-first test runner: suites are plain `.nu` files and a run returns a table
(`suite name status duration error file`) while progress renders on stderr. `help test` and the module header
are the reference; this page covers how to use it and why it works the way it does.

## Writing a suite

```nushell
# tests/suites/greet.nu
use ../mod.nu *          # the seam: assertions, `skip`, sandbox helpers, the module under test

def "test hello says hi" []: nothing -> nothing {
  assert equal (greet hello) hi
}

def "test needs fish" []: nothing -> nothing {
  if (which fish | is-empty) { skip "fish is not installed" }
  # ...
}
```

- A test is a `def "test <name>"` defined **in the suite file**, or any command with the `@test` attribute
  (`use std/testing *` makes the attributes parse). Imported commands never count, even when named `test …`.
- Tests run in the order they are defined.
- `# ignore …` as the description (or `@ignore`) reports a test as `skip` with reason `ignored` without running it.
- `skip "<reason>"` aborts a test as `skip`. Use it for runtime conditions (missing program, wrong OS, no
  credentials) so that an unavailable dependency never reads as passed or failed.
- Statuses: `ok`, `fail` (the test raised), `skip`, and `error` (infrastructure: a hook failed, the suite did not
  load, or the child interpreter died before reporting).

### Hooks

| Hook | Runs | Receives (`$in`) | Output becomes |
|---|---|---|---|
| `def "before all"` / `@before-all` | once per child interpreter, before its tests | nothing | the suite context |
| `def "before each"` / `@before-each` | before every test | the suite context | the test context |
| `def "after each"` / `@after-each` | after every test, **even when it failed** | the test context | — |
| `def "after all"` / `@after-all` | once per child interpreter, after its tests | the suite context | — |

A test receives the test context as `$in` (the suite context when there is no `before each`, null when there are
no hooks). Hooks that must change the tests' environment are declared `def --env`. A failing hook is reported as
an `error` naming the hook (`before each failed: …`); a failing `after all` adds a `(after all)` row.

### Seams

A seam is a `mod.nu` next to the suites directory that re-exports what every suite needs, so suites start with a
single `use ../mod.nu *`. Import the module under test *before* `export use test skip`: the runner's `skip`
would otherwise shadow the builtin `skip` inside modules parsed after it. `test init` writes a seam and stubs.

## Running

```nushell
test                          # suites from the configured `paths` (default: tests/suites)
test tests/suites/greet.nu    # one file; directories are searched recursively (skipping mod.nu seams)
test --match '^gr' --test 'hi$'
test --isolation suite        # one child per suite: faster, less isolated
test --jobs 4                 # run tests concurrently (test isolation)
test --strict                 # raise when anything failed (CI, git hooks)
test --no-sandbox             # use the real HOME/XDG dirs (e.g. for tests that need credentials)
test | where status != ok     # it's just a table
```

`--depth` limits how deep directories are searched: `1` means only files directly in the directory.

## Isolation model

Every discovery and every test runs in a **child interpreter** (`nu --no-config-file`): one per test by default,
or one per suite with `--isolation suite`. Suites therefore cannot affect each other, the invoking shell, or the
module state under test, and `before all`/`after all` run around each test in test isolation.

Children start from a **scrubbed environment**: only an allowlist (PATH, HOME, USER, TERM, LANG/LC_*, TMPDIR,
XDG_RUNTIME_DIR and their Windows equivalents) survives, plus configured `passthrough` names and `env` values. A
suite gets the same results from an interactive shell (where variables like `EDITOR`, `ZELLIJ`, `WORK` or
`mods_home` are exported) and from CI. `--no-scrub` opts out. Where an `env` program exists (Linux, macOS, WSL) the child's environment is
built from scratch with `env -i`; elsewhere the runner falls back to `hide-env`, which Nushell silently ignores
once a `do --env` has run anywhere up the call stack, so scrubbing is best-effort there.

The runner writes each test's literal command name into the child program. Nushell has no string-eval, and a
`$name` in command position evaluates to the string instead of calling the command, which would make every
test vacuously pass.

## Configuration

Settings come from four layers, lowest precedence first:

1. built-in defaults (`test config --defaults`);
2. `$env.NU_TEST`, a record (or its nuon text) that acts as the global default/override, e.g. set in `config.nu`;
3. the nearest `nutest.nuon` at or above the suite file (above `$env.PWD` when deciding which `paths` to search);
4. command flags.

| Key | Default | Meaning |
|---|---|---|
| `paths` | `[tests/suites]` | Suite files/directories searched when no paths are given |
| `lib-dirs` | `[]` | Extra `--include-path` directories for children |
| `isolation` | `test` | `test` or `suite` |
| `depth` | `3` | Directory search depth |
| `jobs` | `1` | Concurrent tests (test isolation) |
| `scrub` | `true` | Start children from the allowlisted environment |
| `passthrough` | `[]` | Extra variable names kept when scrubbing |
| `env` | `{}` | Variables set in every child |
| `sandbox` | `false` | Give every runner child (discovery and tests) a throwaway HOME/XDG tree |

Scalars take the highest layer that sets them; `lib-dirs` and `passthrough` accumulate (most specific first) and
`env` records merge. Relative paths resolve from the file that names them (`nutest.nuon`) or from `$env.PWD`
(`$env.NU_TEST`, flags). The directory containing the `test` module is always appended to `lib-dirs`, so suites
and seams can `use test`. Unknown keys and invalid values are errors that name their source.

`test config [location]` shows the effective configuration; it is exactly what children receive in
`$env.NU_TEST`, so `test exec` inside a test starts a grandchild configured identically.

Because `lib-dirs` in `nutest.nuon` are relative to the file, a repository that lists itself (`lib-dirs: [.]`)
resolves its own modules correctly from any checkout or worktree, regardless of what the caller's `NU_LIB_DIRS`
points at.

## Sandboxes

- `sandbox: true` in the configuration runs every discovery and test child with `HOME` and `XDG_*` pointing
  into a fresh temp tree that is removed afterwards. Modules that persist state (`std-rfc/kv --universal`,
  caches, tool databases under the data dir) then never touch the real ones, and tools that read credentials
  from `HOME` see none, so tests needing them skip. `test exec` and `sandboxed` are not affected.
- `with-sandbox {|ctx| … }` creates a temp directory with `home`, `config`, `data` (including the `nushell`
  directory `std-rfc/kv` needs), `cache`, `state` and `code`, removes it afterwards even on failure, and
  re-raises failures (a `skip` inside stays a skip).
- `sandboxed $ctx '<code>' --prelude 'use mymod *' [--pipe] [--vars {…}]` runs code in a child whose `HOME` and
  `XDG_*` point into the sandbox, so parse-time paths derived from `$nu.home-dir`/`$nu.data-dir` land there.
- `exec '<code>' [--pipe]` runs code in a child configured like a test child; handy for debugging module
  resolution.

## Testing the runner itself

`_tests/selftest.nu` exercises the runner without using it to test itself: `nu _tests/selftest.nu [regex]`.
Run it after any change to `test/mod.nu`.
