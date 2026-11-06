# Module partition: abstract vs. configuration-dependent

Every module in this library falls on one side of a line:

- **Abstract** modules are pure Nushell. They assume nothing about the machine beyond a working `nu` (latest
  nightly) and its standard libraries (`std`, `std-rfc`). They behave identically on any host, under any user
  config, and can be tested hermetically with no set-up beyond a temp directory.
- **Configuration-dependent** modules only work when something outside the library is in place: an installed
  program, a particular OS or host, an environment variable, a path on the owner's machine, the owner's Nushell
  configuration (hooks, `$env.config`), credentials, or a service.

The line runs through some modules rather than around them: a module can expose pure helpers alongside commands
that shell out. The tables below record the classification at command granularity where it matters.

## Why the partition matters

1. **Portability.** Abstract modules are the reusable core: anyone can `use` them. Config-dependent modules are
   the owner's environment glue. An abstract module must never import a config-dependent one; doing so silently
   reclassifies it (e.g. a pure helper that imports `conf` drags in its environment block, which reads the machine
   override file).
2. **Testing.** Abstract modules get full, unconditional test coverage. Config-dependent modules are tested in
   two tiers: the logic that can be isolated (argument construction, parsing, state handling) runs everywhere by
   sandboxing state and stubbing externals with scripts on `PATH`; anything that needs the real dependency is
   guarded with `skip "<reason>"` so a missing tool reads as *skipped*, never as *passed* or *failed*.
3. **Loading.** Config-dependent modules often do work at import time (`export-env`). Keeping that work out of
   abstract modules keeps `use` cheap and side-effect free.

## Dependency kinds

| Kind | Examples in this library |
|---|---|
| External program | `timew`, `td` (Todoist CLI), `git`, `fish`, `carapace`, `zellij`, `sudo`, `sshfs`, `systemctl`, `oh-my-posh`, package managers |
| OS / host | WSL interop (`/mnt/c`, `powershell.exe`), the machine override file (`_docs/machine-config.md`), Linux `reset`/`umount` |
| Environment variable | `WORK`, `NUPM_HOME`, `mods_home`, `EDITOR`, `ZELLIJ`, `TIMEWARRIORDB`, `IPEX_LLM_OLLAMA_HOME` |
| Nushell config | `$env.config.hooks`, `$env.config.color_config`, `buffer_editor` |
| Persistent state | `std-rfc/kv` tables (universal SQLite under `$nu.data-dir`), msgpack caches, files under `WORK` |

Persistent state alone does not make a module config-dependent: if the state location follows `$nu.data-dir` /
XDG variables, the module is still abstract and is tested by redirecting those variables.

## Abstract modules

| Module | Notes |
|---|---|
| `validate` | Rule engine and string validators. Colored output uses `nu-highlight` only. |
| `types` | Cell-path and type helpers. |
| `error` | `error raise` with coded errors. |
| `log` | Thin wrappers over `std/log`. |
| `var` | Named values in `std-rfc/kv` (state follows `$nu.data-dir`). |
| `env` | `.env` parsing, env-var helpers. `env from-bash` runs `bash` (and `env`) to read a bash script's variables; bash is not counted as a dependency, since a bash script implies it. |
| `path` | Path rewriting helpers. `path select` is interactive (needs a TTY). |
| `completion` | Builds completion records (`into completions`, `into spans`). |
| `hook` | Reads and edits `$env.config.hooks`; pure over the config record. |
| `docgen` | Collects module docs by running the current `nu` binary on the target module. |
| `alarm` | In-memory timers via jobs; expiry notifies through `set --notify` (default: print the text). |
| `mods` | Module registry (kv), listing, `define` (`--directory` or `mods_home`). `mods/local` adds `edit`. |
| `util` | `contains`, `timestamp`; `util workspace bump` is abstract logic that optionally calls formatters (`tombi`, `dprint`); `deactivate` expects an overlay named `__workspace__`. |
| `command` | `post-complete` on a `complete` record is abstract; `attempt` and closure input necessarily run externals. |

## Configuration-dependent modules

| Module | Depends on |
|---|---|
| `conf` | The machine override file (`machine.nuon`/`machine.nu` in Nushell's config directory or `NU_MACHINE_CONFIG`; `_docs/machine-config.md`): a script runs in a child `nu`. The library is host-neutral — `conf/machine.nu` holds only defaults derived from `$nu`, and the owner's former host branch is the example script `_docs/examples/machine.nu` (`~/.profile` via `env from-bash`, `WORK`, `NUPM_HOME`). Also the editor (`edit`) and `oh-my-posh` (`prompt`). Its `export-env` adds missing directories to `NU_LIB_DIRS`/`NU_PLUGIN_DIRS`/`PATH`. Not split: the whole module is machine configuration. |
| `mods/local` | `edit` and its completions resolve through `conf machine-config`. |
| `pman` | Package managers, cargo; `bump-nu` downloads the latest Nushell nightly (network: GitHub's API and release assets), extracts it with `tar`, writes the nu binary and edits the plugin registry. Destructive. |
| `link` | `sudo`, `ln`, `unlink`; Windows `cmd /c mklink`. Privileged. |
| `edit` | `$EDITOR` / `buffer_editor`, `zellij`. |
| `elevate` | `sudo`. Privileged. |
| `reload` | `reset` (only with a TTY on stdin), re-`exec` of the shell binary. |
| `windows` | WSL interop (`/mnt/c`, `powershell.exe`, `where.exe` — resolved on PATH/WINPATH, else System32 — and `wslpath`). |
| `mount` | `sshfs`, `fusermount3`, `mount`/`umount` (bind mounts need root), `mountpoint` or `findmnt`. Privileged. |
| `ipex-llm-ollama` | `systemctl` service, `bash`, vendor scripts (`start-ollama.sh`, `ls-sycl-device`), `IPEX_LLM_OLLAMA_HOME` (default `~/.local/share/ipex-llm-ollama`). |
| `proj` | `$env.WORK` directory tree, `git`, kv registry; scans on import when `WORK` is set (`scan`/`kind` need it). `--boot` needs `zellij`. |
| `track` | `timew`, `git`, optional `td`; installs the `track::sync`/`track::focus` hooks on import (deduplicated); focus per shell in `$env.TRACK`, only `disabled` in universal kv. |
| `alarm/local` | `tui` commands and an interactive terminal for the expiry dialog; prints the text without them. |
| `time` | `timew` (hermetic with a temp `TIMEWARRIORDB`). |
| `todo` | `td` CLI, Todoist credentials, network. Parsing/formatting helpers are pure. |
| `completion/local` | `fish`, `carapace`; mutates `$env.config`; its export-env sets `CARAPACE_*` and the carapace `PATH` entry. `fish-complete parse-output` is pure. `completion/external` is a deprecated shim for it. |
| `style` (mild) | Reads `$env.config.color_config`; falls back to Nushell's default colors. |
| root `mod.nu` | Aggregates config-dependent modules; parses with only the repository on the lib path; its `export-env` runs the conf/mods/completion/proj/track/windows env blocks as guarded `use` statements. |

## Splitting mixed modules

A module that mixes abstract logic with configuration-dependent logic keeps the abstract part in `<module>/mod.nu`
and puts the dependent part in `<module>/local/mod.nu`, which re-exports the abstract commands and adds (or
overrides) the dependent ones. `alarm`, `completion` and `mods` are split this way; the barrel exposes the local
variants under the original names. `use <module>/local` prefixes commands with `local`, so import it with `*`, a
selection, or through the barrel. Re-export a parent's `main` explicitly (a re-exported `main` takes its module's
name, `mod`). Modules that are configuration-dependent as a whole (`conf`, `proj`, `todo`, …) are not split.

The root barrel exposes the local variants as bare names (`alarm set`, `mods edit`, `set-completer`); no
`local …`-prefixed form exists anywhere (a prefixed name and its bare twin are one declaration, so they could not
be hidden separately and would clutter completions). `init-local` writes an autoload file holding `use <root> *`,
which bootstraps a fresh machine on its own. The barrel runs the environment blocks it needs as guarded `use`
statements inside its own `export-env`: the modules are already parsed, so this costs nothing beyond the block
itself (`source-env` would re-parse each file as a script on every load and execute its `use` statements
unguarded).

The root barrel's `local` module gathers every local variant under its module's name: `use <library root> local`
gives `local alarm …`, `local completion …` and `local mods …`, and `use <library root> *` exposes `local …` as
well. A new split module gets an entry there. The variants are re-exported with `export use` of a module named after
the original (for `alarm` and `mods`, the barrel's wrappers that declare `main`), not with `export module`: an
import reaches one level of a module's commands, so a submodule of `local` would not be callable as
`local <module> …`.

## Outside code

Nothing outside the repository is imported at parse time, and no third-party code is vendored. Two components
started as outside code and were adopted as first-class module members instead: `pman bump-nu` (from the owner's
`nightly-toolkit` rewrite) and `env from-bash` (a jq-free reimplementation of the owner's `bash-env` fork; its
header credits tesujimath/bash-env-nushell, MIT). If outside code the library must execute ever appears again,
vendor it under the module that uses it, import it relatively, and record its provenance here.

## Rules of thumb for new code

- Vendor outside code the library runs (modules, scripts) and import it relatively. Host-specific values (paths,
  directory layouts) go in the machine override file (`_docs/machine-config.md`), never in a module: the library
  holds no host names.

- Put pure logic in an abstract module (or a private helper) and keep the external call at the edge, so the logic
  can be tested without the dependency.
- Derive state locations from `$nu.data-dir`/`$nu.cache-dir` or XDG variables, never hard-coded home paths, so tests
  can redirect them.
- Avoid parse-time absolute imports (`use /abs/path`) in modules that others import: they make every importer
  fail to parse on other machines.
- When a module needs set-up at import time, make the `export-env` idempotent (re-`use` must not stack hooks or
  duplicate `PATH` entries).
