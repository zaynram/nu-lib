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
- The runner calls each test by writing its name into the child program, so a name must parse as bare words:
  no quotes, brackets, braces, `|`, `;`, `#`, `^`, `%`, `>`, and no word starting with `$`. Other names are reported
  as `error` ("this name cannot be called") without stopping the rest of the suite.
- A description whose first word is `ignore` (`# ignore`, `# ignore: not ready`), or an `@ignore` attribute, reports
  a test as `skip` with reason `ignored` without running it. A description that merely starts with those letters
  (`# Ignores leading whitespace`) is not a marker.
- `skip "<reason>"` aborts a test as `skip`. Use it for runtime conditions (missing program, wrong OS, no
  credentials) so that an unavailable dependency never reads as passed or failed. A `skip` raised in `before all`
  or `before each` skips the affected tests. Importing it shadows the builtin `skip` in the suite (and in modules
  parsed after it): use `drop nth 0` (or `slice 1..`) to drop list items in suites, and do not apply nu-lint's
  `slice_to_skip` suggestion there, since `skip 1` would then be the runner's `skip` with reason `1`.
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

Progress on stderr is coloured only when `config use-colors` says so (`$env.config.use_ansi_coloring`, the
`FORCE_COLOR`/`NO_COLOR`/`CLICOLOR` variables, whether stdout is a terminal; `style/mod.nu` has the precedence),
decided once per run. Test children never see a terminal, so inside a test colours
are off unless the test sets `$env.config.use_ansi_coloring = true` itself (it is a per-process setting).

## Isolation model

Every discovery and every test runs in a **child interpreter** (`nu --no-config-file`): one per test by default,
or one per suite with `--isolation suite`. Suites therefore cannot affect each other, the invoking shell, or the
module state under test, and `before all`/`after all` run around each test in test isolation.

Children start from a **scrubbed environment**: only the `KEEP` allowlist in `test/mod.nu` survives — `PATH`/`Path`,
`HOME`, `USER`, `USERNAME`, `LOGNAME`, `SHELL`, `TERM`, `COLORTERM`, `LANG`, `LANGUAGE`, `LC_*`, `TZ`, `TMPDIR`,
`TEMP`, `TMP`, `XDG_RUNTIME_DIR`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` and, for
Windows, `SYSTEMROOT`/`SystemRoot`, `WINDIR`, `COMSPEC`, `PATHEXT`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` —
plus configured `passthrough` names and `env` values. A suite gets the same results from an interactive shell
(where variables like `EDITOR`, `ZELLIJ`, `WORK` or `mods_home` are exported) and from CI. `--no-scrub` opts out.
Where an `env` program exists (Linux, macOS, WSL) the child's environment is built from scratch with `env -i`;
elsewhere the runner falls back to `hide-env`, which Nushell silently ignores once a `do --env` has run anywhere up
the call stack, so scrubbing is best-effort there.

Children also get an empty stdin and, where `setsid` exists, no controlling terminal, so a test that waits for
input (`input`, a prompt, a TUI) fails instead of hanging the run (`input` reads the terminal, not stdin). The
flip side: Ctrl-C reaches the runner, not the detached child, so an interrupted run ends when the current child
does; set `timeout` to bound a hung child. The allowlist keeps `XDG_*_HOME`, so `--no-sandbox` sees custom XDG
directories (credentials, kv stores) where the user keeps them.

The runner writes each test's literal command name into the child program. Nushell has no string-eval, and a
`$name` in command position evaluates to the string instead of calling the command, which would make every
test vacuously pass.

A child's stdout carries results only, as tagged lines: whatever a suite prints while it loads (a top-level
`print`, a module's `export-env`) or a test prints is discarded, and so is the child's stderr unless the child
dies before reporting (it is then attached to the `error` rows). Put diagnostics into assertion messages.

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
| `timeout` | `0sec` | Kill a child that runs longer (reported as `error`, "timed out"); needs the `timeout` program, without which the run warns once on stderr and the bound is not enforced |

Scalars take the highest layer that sets them; `lib-dirs` and `passthrough` accumulate (most specific first) and
`env` records merge. Relative paths resolve from the file that names them (`nutest.nuon`) or from `$env.PWD`
(`$env.NU_TEST`, flags). The directory containing the `test` module is always appended to `lib-dirs`, so suites
and seams can `use test`. Unknown keys and invalid values are errors that name their source; that includes
`resolved` and `project`, the keys the runner adds to the configuration it hands children, which only a complete
resolved record in `$env.NU_TEST` (what `test config` returns) may carry.

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

## This repository

```
nutest.nuon          # paths: [_tests/suites], lib-dirs: [.], sandbox: true
_tests/
  mod.nu             # shared seam: std/assert, skip, with-sandbox, sandboxed, ROOT, FIXTURES
  selftest.nu        # framework-free test of the runner
  fixtures/<module>/ # fixture files, outside suite discovery
  suites/<module>.nu # one suite per module; submodules are covered by their parent's suite
```

Every suite starts by importing what it tests, then the seam:

```nushell
use validate
use ../mod.nu *
```

Modules resolve from the repository root, so a worktree tests its own code. Children are sandboxed, so suites for
modules with persistent state need no clean-up of real data; suites that must reach real services gate on an
opt-in variable listed in `passthrough` and skip otherwise (run them with `--no-sandbox`).

## Testing the runner itself

`_tests/selftest.nu` exercises the runner without using it to test itself: `nu _tests/selftest.nu [regex]` (a
regex that selects no case exits with status 2). Run it after any change to `test/mod.nu`.
