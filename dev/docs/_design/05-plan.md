# 05 — Plan: redesign the issue tooling as `_internal/dev`

Written 2026-09-18 as a clean rewrite of the 2026-09-14 plan. Authoritative documents:
`dev/docs/2026-09-18_dev-core.spec.md` (schema, six local commands) and
`dev/docs/2026-09-18_dev-sync.bindings.md` (D6 to D9 and every sync commitment); where this plan and
either differs, the document wins. The audit that produced the verdict is `00-scope.md` to
`04-handoff-prompt.md` beside this file (historical, superseded by the spec on every point of schema
and naming); the ownership map and lifecycle trace are `06-ownership.d2` and `07-lifecycle.d2`.

Each phase runs in a fresh session. Start every session by reading the files under its "Read first"
list; nothing else is assumed to be in context.

Branch: `feat/dev-module`, rebased onto `main` at `ffd8eb0` (the 2026-09-18 library reorganisation:
`todo` wrapper, `prelude`, `elevate with-auth`, `util contains`/`attempt`). Commit per completed
phase. Never push without an explicit request.

## Phase 0 — Documentation discovery (completed 2026-09-14, re-verified 2026-09-18)

Every item below was verified by running the command named, on the tree at `main` `ffd8eb0`.

### Allowed APIs

Nushell 0.115.2 (nightly.24) builtins: `mktemp`, `path self`, `to md`, `to toml`, `from toml`,
`into datetime`, `format date`, `into cell-path`, `merge deep`, `random uuid`; plus `open`, `save`,
`mv`, `glob`, `input`, `error make --unspanned`, `std/assert`.

`to toml` (probe 2026-09-18): `list<record>` serialises as `[[name]]`; nested `record` as `[a.b.c]`
headers; scalar keys precede sub-tables whatever the record order; `null` serialises as the string
`"<Nothing>"` (strip nulls first); `datetime` serialises as `2026-09-14T00:00:00.0+00:00` (format
with `format date %F` first); a multi-line string serialises as a `"""` literal; no inline tables.

`open` on a v3 file: parses (Nushell tolerates the multi-line inline tables that `tomllib` rejects in
most of them); `issue.date` arrives as `datetime`; `tasks` is a record keyed `"1"`, `"2"` (one file
`"0"`); `issue.status` takes `open`, `completed`, `draft`, `aborted`. The 14 files and their 44
distinct leaf paths are enumerated in the spec's Migration mapping.

`_internal/todo` (`todo/mod.nu`): `main [...rest --json --ndjson --long]` L16 is the `td` passthrough
(`--json` parses and hydrates task-shaped rows); `list [--project --label --parent --filter
--completed --since]` L30 (`--parent` is ignored with `--completed`, L38-43) returns `table<id content description labels project parent due priority
url>`; `view [ref]` L55; `add [content --project --description --labels --parent --due --priority]
-> record` L61; `edit [ref --content --description --labels --due --no-due --priority]` L82; `done
[...refs]` L103; `reopen [...refs]` L108; `rm [...refs]` L113; `projects [] -> table<id name url>`
L123; `labels []` L128; `find [slug --project --threshold]` L137 (null on a tie). Refs are an id,
`id:<id>`, or exact content. Every call goes through the private `todoist` helper L157 (JSON reads
via `util attempt --merge`, writes via `elevate with-auth`).

`_internal/util` (`util/mod.nu`): `contains [cell: cell-path]` L19 (accepts `?`/`!` suffixes);
`timestamp` L28; `--wrapped attempt [name ...rest --check --merge]` L33; `editor [--cd --depth ...]` L55.

`_internal/elevate` (`elevate/mod.nu`): `--wrapped with-auth [name --login: closure --pattern
--strict ...rest]` L50, the auth-retry wrapper for `gh` and `td`.

`_internal/completion` (`completion/mod.nu`): `into completions [options: record = {} --to-string:
closure --repr: record]` L41 wraps a list or `value`/`description` table into `{options,
completions}`; strings are nuon-quoted only when a bare argument would misparse. Import it directly
(`use ../completion "into completions"`); `util` no longer re-exports it.

`_internal/dispatch` (`dispatch/mod.nu`): `dispatch type {<type>|<type|type>|_: <value or closure>}
--pipe|--exec [--default]` matches the `describe` name of the input and pipes or runs the closure.

`_internal/repo` (`repo/mod.nu`): `$env.repo.path` is `table<name owner directory>` built by
`hydrate-git-context` L229; `repo list [regex?]` L107; discovery honours `$env.repo_exclude` L258;
`run-gh-with-repo` L304 is the `gh` error shape to copy. No aliases column yet (Phase 3b).

Import rule: std submodules only (`use std/assert`, `use std/util [repeat structure]`); `use std
<name>` loads the whole root module (about 40 ms at login).

`gh` 2.101.0: `issue create -R owner/repo -t <title> -F - -l <label>` (body on stdin, prints the
URL); `issue edit <n> -R owner/repo -F -` (also `--milestone`, `--add-label`, `--remove-label`);
`issue view <n> -R owner/repo --json number,url,state,title,body`; `issue list -R owner/repo --state
all --json number,title,state,url --limit N`; `issue close <n> -R owner/repo --reason
{completed|"not planned"}`; `issue reopen <n> -R owner/repo`. Milestone endpoints (`gh api
repos/{owner}/{repo}/milestones`) are unprobed; Phase 4 confirms them.

`claude` 2.1.278: `-p/--print`, `--session-id <uuid>`, `-r/--resume <session-id>`, `--output-format
{text|json|stream-json}` (only with `--print`).

`td` 5.3.9: `td completed list [--project --since --until --limit --all --json --full]` has no
parent filter; filter the `parent` column client-side; `--since` defaults to today, three-month
window. `td task add [--project --labels <a,b> --parent <ref> --description]`.

Strict TOML check: `python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' <file>`
(Python 3.14.7). Diagrams: `d2` 0.7.1 at `~/.local/bin/d2`.

Old module, copy-worthy fragments only: slug discovery glob
`~/.local/share/nupm/modules/issue/mod.nu:344-349` (`_issue-slugs`); URL to index parse
`parse '{_}/issues/{index}'` at `~/.local/share/nupm/modules/issue/mod.nu:209-213`.

Test seam to copy: `time/tests/mod.nu` (module under test, `std/assert`, then the runner's `skip`;
`completion/tests/mod.nu` lacks `skip`).

### Anti-patterns (do not do)

- Do not `use` the nupm `issue` or `tasks` modules; do not touch sqlite (`stor`, `query db`).
- Do not run `git commit`, `gh issue develop`, or any command that changes the user's branch or history.
- No `...rest` passthrough to `gh` or `td` from `dev` commands; every flag `dev` accepts is in its own
  signature. No `^td` anywhere in `dev/mod.nu`; the `todo` module is the only Todoist path.
- Do not export commands named `update`, `rm`, `find`, `get`, `export` (spec, Naming). Run ide-check
  on `dev/mod.nu` after adding each export.
- Do not write `null` or `datetime` values through `to toml` (Phase 0 facts).
- Do not build a local index or cache of tickets; `$env.repo.path` plus `docs/tickets/*.toml` is the
  whole discovery model.
- `try { }` without `catch` returns null; do not rely on it to propagate errors.
- Do not wrap a record with std-rfc `into list` (it yields a key/value table); `append []` wraps any
  value into a list.
- Bare column names inside a parenthesised subexpression of a `where` row condition parse as
  commands; use `where {|r| (...) }` with the whole expression parenthesised.
- Do not nest a module's env bootstrap behind `export use` and expect its `export-env` to run; it does
  not (verified 2026-09-18, `/tmp/t4.nu`); `source-env` or a direct `use` inside the parent's
  `export-env` is the working form.
- Quote every string that starts with `-` when it is an argument to a Nushell-defined command:
  `f -agent` is `nu::parser::unknown_flag`, `f '-agent'` is the string (verified 2026-09-19). Inside
  list and record literals a bare `-agent` parses as a string, but quote it there too (the formatter
  does). Nushell passes `-agent` and `'-agent'` identically to an external, so for `td` the quotes
  change nothing: `td label create` takes no positional (`--name` only) and `td label update` reads a
  dash-leading ref as an option, so it needs `-- '-agent'`.

## Phase 1 — Spec: `dev` core (completed 2026-09-18)

Deliverables: `dev/docs/2026-09-18_dev-core.spec.md` and `dev/docs/2026-09-18_dev-sync.bindings.md`,
both clean rewrites of the 2026-09-15 draft and its amendments after the sync design thread of
2026-09-16 to 18. Decisions keep their numbers: D1 to D5 and D10 to D15 in the core spec, D6 to D9 in
the bindings document.

Gate: the user reads both documents and approves before Phase 2 starts.

## Phase 2 — Build A: schema, `dev`, `dev list`, `dev query`, `dev edit`

Files: `_internal/dev/mod.nu` (new), `_internal/dev/tests/mod.nu` (new seam),
`_internal/dev/tests/suites/dev.nu` (new).

Read first: the core spec (Schema, Contract, Behaviour, Validation, Tests), Phase 0,
`time/tests/mod.nu` (seam to copy verbatim), `time/tests/suites/time.nu:1-9` (before/after each),
`todo/tests/suites/todo.nu:14,27` (`skip` and the write gate), `todo/mod.nu:1-14` (module header and
imports to copy), `completion/mod.nu:41`.

Tests first. `dev/tests/suites/dev.nu`:

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
  $env.repo = {discovery: false path: [{name: scratch owner: me directory: $t.root}]}
  assert equal (dev list) []
}
```

One `def "test <name>"` per bullet of the spec's Tests section, Phase 2 list, each setting
`$env.repo` from `$in.root` first; the runner spawns one child interpreter per test, so tests share
only the fixture.

Then implement, in this order, each as the minimum that passes:

1. Discovery: `files [] -> table<slug repo path>` from `$env.repo.path` and
   `glob (dir | path join docs tickets '*.toml')` (pattern at `~/.local/share/nupm/modules/issue/mod.nu:344-349`).
2. `dev [slug --repo --md]`: `open`, the checks listed under the spec's Behaviour (`version`, required
   keys and types, `status`, slug charset, stem match, attribution labels, `into datetime`); `--md`
   per the spec's `--md` bullet (`to md` for the two tables).
3. `dev list [--status --repo]`: `files | each { open | select ... }`.
4. `dev query [slug property: cell-path]`: `dev $slug | get $property`.
5. The writer and `dev edit [slug --set --add-task --complete]`: merge `--set` (D14), rebuild in
   canonical order, compact nulls, `format date %F`, `to toml`, `save --force` to
   `mktemp --tmpdir-path <same dir> --suffix .toml`, then `mv --force` over the original.
   `--add-task` and `--complete` only raise the "no Todoist task yet" error in this phase; their
   Todoist leg is Phase 5a.
6. Completers: `_slugs` from `files`, `_repos` from `$env.repo.path.name`, `_statuses`,
   `_properties`, all through `into completions`.

Verification: `nu --no-config-file --experimental-options=all --ide-check 500 dev/mod.nu | grep -c
'"message"'` is 0; `nu-lint --format=compact dev` clean; `test dev/tests/suites` reports every test
`ok`; `grep -nE 'stor |query db|git |gh |\^td|\.\.\.rest|<Nothing>' dev/mod.nu` is empty.

Guards: export names per the spec's Naming; no cache; no `try {}` without `catch` on the write path;
the temp file lives in the target directory so `mv` is a rename, not a copy.

Scope: four analytical tasks. If `edit` grows past merge-rebuild-write, stop and split.

## Phase 3 — Build B: `dev new`, `dev migrate`

Files: extend `_internal/dev/mod.nu` and `_internal/dev/tests/suites/dev.nu`; add
`_internal/dev/docs/example.toml` (the spec's example, byte for byte).

Read first: the core spec (D2, D5, D13, D15, Behaviour for `new` and `migrate`, Migration mapping,
Tests Phase 3 list), Phase 0 (`claude`, `input`, `util editor` L55), the v3 files named in the tests
(`~/code/nu-fluency/docs/issues/hooks-placement.issue.toml`,
`~/code/nushell-mcp/docs/issues/{windows-portability-batch,include-dirs}.issue.toml`,
`~/code/ramda-doc/docs/issues/polyglot-reference-autodoc-tooling.issue.toml`).

Tests first: one `def "test <name>"` per bullet of the spec's Tests section, Phase 3 list, copying
the named v3 files into the scratch repository's `docs/issues`.

Implement:

1. `dev new [slug --name --interactive --continue --prompt --recover --files --edit]` (signature in
   D5): validate the slug (D13), build the record from the spec's example shape (name defaults to the
   slug with `-`/`+` as spaces, title-cased), `--interactive` prompts `name`, `outcome`, `requirements`
   and `constraints` with `input` per D5 and the spec's Behaviour (lists take one item per line),
   `--prompt` per the spec's Behaviour, write through the Phase 2 writer, `--edit` calls `editor`.
   `const EXAMPLE: path = path self ./docs/example.toml`.
2. `dev migrate [...slugs --all --dry-run --repo]`: read `docs/issues/<slug>.issue.toml`, refuse
   `version != "3.0.0"` and the refused shapes naming the offending path, drop `tasks` (D2), map every
   other leaf per the Migration mapping (`completed` becomes `done`; `extends` paths reduce to slugs),
   write `docs/tickets/<slug>.toml` through the writer, remove the source (D15), return
   `table<slug from to changed>` with paths.

Verification: same ide-check, nu-lint and test commands as Phase 2; additionally every
`<scratch>/docs/tickets/*.toml` passes `tomllib`, and `<scratch>/docs/issues` holds only the refused
file.

Guards: `--prompt` is not tested live (it costs a model call); test the parse-failure branch with a
stub string instead. `--interactive` is not tested (`input --reedline` needs a terminal); the values
it collects feed the same writer as the non-interactive path, which the tests cover. No generic shape mapper; refused shapes error.

## Phase 3b — `repo` aliases (own branch, `feat/repo-aliases` from `main`)

Files: `_internal/repo/mod.nu`, `_internal/repo/tests/{mod.nu,suites/repo.nu}` (new; seam copied
from `time/tests/mod.nu`), `_internal/todo/mod.nu` (`repo-name` L211, `find` L137),
`_internal/track/mod.nu:37` (the hook's `todo find $branch --project $repo`, spec
`track/docs/2026-09-13_track-hook.spec.md:51`). `repo` has no spec or tests today; this phase adds the
suite, not a spec.

Read first: `repo/mod.nu:229-260`, `todo/mod.nu:137-156`, `track/mod.nu:30-40`, Phase 0's `repo` line,
the bindings document's D7.

Write: a registry column `aliases: list<string>` per row, empty by default, set with
`repo push <dir> --alias <project>` or `--alias <project>/<section>` (append, `uniq`); `repo list`
shows it. `todo find --project` and the track hook resolve the Todoist project by trying the
repository name first, then each alias in order (a `project/section` alias filters `todo list` to
that section). One test per resolution step against a fake `$env.repo.path`. This is the seam
`dev sync` uses for `development` (sections map to `~/.config` and `~/library/nushell/_internal`) and
`nupm-registry`; no `dev` code changes here.

Verification: `test repo/tests/suites`, `test todo/tests/suites`, `test track/tests/suites` all
`ok`; ide-check and nu-lint clean on the three modules. Merge to `main` before Phase 4; rebase
`feat/dev-module` afterwards.

## Phase 4 — Spec: `dev sync`

Deliverable: `dev/docs/<today>_dev-sync.spec.md`. No code. Replace the placeholder sentence in the
core spec's intro with the real path.

Read first: the bindings document in full, its Scope section first (mandatory: every commitment, D6
to D9, the breakdown table, and "Left to the sync spec", which is this phase's decision list), the core spec (Ownership, D1, D12, D13, Behaviour
for `edit`), Phase 0 (`gh`, `td`, `todo`, `elevate with-auth`), `06-ownership.d2` and
`07-lifecycle.d2`, `todo/mod.nu:137-186`, `repo/mod.nu:304-318`, the Phase 3b alias resolution.

Write, following the todo spec's section shape (Purpose, Decisions, Contract, Behaviour, Naming,
Verification): the contract from the bindings document's "Command surface"; the algorithm as ordered
"ensure" steps per leg (Todoist, remote issue, milestone) so re-running is a no-op, each step naming
the exact `todo`/`gh` call, with the D8 checklist read-back placed before the row mirror; the dry-run and result row shapes; error copy for every case in the
bindings document's breakdown table; the report-only cases as result rows; the `gh api` milestone
calls confirmed against `gh api --help`; the remote reads per leg and their cost; tests split into
offline (the D6 decision table as a pure function, row diff, body rendering, milestone decision) and
opt-in live (D9); the verification guard that replaces the core spec's `gh `/`^td` grep.

Verification: every "ensure" step names its call; the idempotence argument is written per step;
every W breakdown maps to a result row or an error; nothing weakens a bindings line; every step is
under the bindings document's Scope "does" list and none under its "never does" list; the words
"GitHub" and "forge" appear only where `gh` is named as the wired CLI; user approves before Phase 5a.

## Phase 5a — Build: Todoist leg and `edit` write-through

Files: extend `_internal/dev/mod.nu` and `_internal/dev/tests/suites/dev.nu`.

Read first: the bindings document's Scope section (mandatory), the sync spec (Todoist leg, D6
decision table, D7), Phase 0, `todo/mod.nu:157-186`
(`todoist` helper), `todo/tests/suites/todo.nu:27` (write gate).

Tests first: offline: the D6 decision as a pure function; the row diff from fake `todo list` rows to
the `[[tasks]]` mirror and closure action; `dev sync alpha --dry-run --skip [remote milestone]` with
no Todoist project errors naming `td project add`.
Opt-in live (`DEV_SYNC_WRITE=1`): sync a scratch ticket into a scratch Todoist project twice, assert
the second run reports no changes, `edit --add-task` then `edit --complete` round-trip (there is no
offline test of `edit`'s write path: it has no dry run), then `todo rm` the created tasks.

Implement the Todoist leg as a private function called from `sync`, all `td` traffic through the
`todo` module; every label about to be attached is checked against `todo labels` first (bindings,
Scope); `edit --add-task`/`--complete` gain their Todoist calls here. Write
`reference.todoist` back through the writer.

Verification: ide-check 0; nu-lint clean; `test dev/tests/suites` all `ok`; the sync spec's guard
grep; `dev sync --all --dry-run --skip [remote milestone]` run twice by the user shows the same
output both times.

Guards: no resume files; no auto-commit; never print `td` tokens; the mirror is written only after
the remote calls succeed.

## Phase 5b — Build: remote issue and milestone legs

Files: extend `_internal/dev/mod.nu` and `_internal/dev/tests/suites/dev.nu`.

Read first: the bindings document's Scope section (mandatory), the sync spec (remote and milestone
legs, D8), Phase 0 (`gh`, `elevate with-auth` L50),
`repo/mod.nu:304-318`, `~/.local/share/nupm/modules/issue/mod.nu:209-213`, Phase 5a's leg as the pattern to copy.

Tests first: offline: `dev alpha --md` body equals the expected string; the D8 toggle rule as a pure
function over `(host box, Todoist state, mirror)` per row, parsed from a fake issue body (a conflict
yields a report, not a call); the milestone decision (create/assign/state) from fake `gh api` rows; `--skip [todoist]` runs the remote legs alone. Live:
D9 (user-driven `--dry-run` against a real issue, then one real sync).

Implement the two legs as private functions, every `gh` call through one private wrapper using
`with-auth --login {|| ^gh auth login } gh ...` that errors with stderr. The issue leg reads the body
once, applies the D8 toggles through the `todo` module, and only then renders and writes the body. Write `reference.remote` back
through the writer after the issue leg succeeds; the milestone leg writes nothing to the file.

Verification: ide-check 0; nu-lint clean; `test dev/tests/suites` all `ok`; `^gh` appears only inside
the wrapper; `dev sync --all --dry-run` run twice by the user against real repositories shows the
same output both times.

Guards: as 5a; never print `gh` tokens; `reference.remote` is written per leg with any skip recorded
in the result row.

## Phase 6 — Verification and cutover

1. Rename the one dotted slug on every surface first: the Todoist task `v0.4.0-close-out`, the v3 file
   `v0-4-0-close-out.issue.toml` and its `issue.slug`, and the nu-fluency issue #8 title all become
   `pre-version-ship-review` (D13). Then `dev migrate --all --dry-run`, hand-edit the two D2 files,
   `dev migrate --all`; then every `~/code/*/docs/tickets/*.toml` passes `tomllib` and
   `~/code/*/docs/issues/` is empty.
2. `dev list` shows all 14 tickets (`dev query <slug> version` is `4.0.0` for each).
3. `dev sync --all --dry-run` twice, identical output. `windows-portability-batch` is completed in
   Todoist while its v3 file says `open` (probe 2026-09-19, left in place on purpose): its dry-run row
   must show D6 closure in (`status = done`, issue closed) and it is the first real `dev sync`, so the
   module is seen resolving it; then one more ticket chosen by the user.
4. Grep guards across `dev/mod.nu`: `stor `, `query db`, `git commit`, `gh issue develop`, `...rest`,
   `<Nothing>` all absent; `^td` absent; `^gh` only inside the wrapper.
5. Cutover: the user removes the nupm `issue` and `tasks` modules and any `use issue`/`use tasks`
   lines in `~/.config/nushell`; `dev/docs/_design/` stays as the tracked design record.
6. Commits: one per phase on `feat/dev-module`; push only when asked.
