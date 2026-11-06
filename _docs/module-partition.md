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
   reclassifies it (e.g. a pure helper that imports `conf` drags in `conf/machine.nu`'s host branches).
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
| OS / host | WSL interop (`/mnt/c`, `powershell.exe`), hostname-specific branches, Linux `reset`/`umount` |
| Environment variable | `WORK`, `NUPM_HOME`, `mods_home`, `EDITOR`, `ZELLIJ`, `TIMEWARRIORDB`, `IPEX_LLM_OLLAMA_HOME` |
| Owner's paths / modules | `/work/ext/bash-env`, nupm modules such as `nightly-toolkit` |
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
| `env` | `.env` parsing, env-var helpers. |
| `path` | Path rewriting helpers. `path select` is interactive (needs a TTY). |
| `completion` | Builds completion records (`into completions`, `into spans`). |
| `hook` | Reads and edits `$env.config.hooks`; pure over the config record. |
| `docgen` | Collects module docs by running the current `nu` binary on the target module. |
| `alarm` | In-memory timers via jobs. *Except* the non-silent expiry path, which launches the `tui` binary. |
| `util` | `contains`, `timestamp` are abstract. `util/workspace bump` is abstract logic but optionally calls formatters; `deactivate` expects an overlay named `__workspace__`. |
| `command` | `post-complete` on a `complete` record is abstract; `attempt` and closure input necessarily run externals. |

## Configuration-dependent modules

| Module | Depends on |
|---|---|
| `conf` | `conf/machine.nu` host branches (hostname, `/work/ext/bash-env`, `.profile`, `$env.work`), editor (`edit`), `oh-my-posh` (`prompt`). Its `export-env` rewrites `NU_LIB_DIRS`/`NU_PLUGIN_DIRS`. |
| `mods` | Mostly kv/in-memory logic, but `edit` and definitions resolve through `conf` machine config and `mods_home`; `define` writes into `mods_home`. |
| `pman` | Package managers, cargo, `nightly-toolkit` (nupm). Destructive. |
| `link` | `sudo`, `ln`, `unlink`; Windows `mklink`. Privileged. |
| `edit` | `$EDITOR` / `buffer_editor`, `zellij`. |
| `elevate` | `sudo`. Privileged. |
| `reload` | `reset`, re-`exec` of the shell binary, a TTY. |
| `windows` | WSL interop (`/mnt/c`, `powershell.exe`, `wslpath`, `where.exe`). |
| `mount` | `sshfs`, `fusermount3`, `sudo`, `mount`. Privileged. |
| `ipex-llm-ollama` | `systemctl` service, `bash`, vendor scripts, `IPEX_LLM_OLLAMA_HOME`. |
| `proj` | `$env.WORK` directory tree, `git`, kv registry; scans on import. `--boot` needs `zellij`. |
| `track` | `timew`, `git`, optional `td`; installs global hooks on import. |
| `time` | `timew` (hermetic with a temp `TIMEWARRIORDB`). |
| `todo` | `td` CLI, Todoist credentials, network. Parsing/formatting helpers are pure. |
| `completion/local` | `fish`, `carapace`; mutates `$env.config`; its export-env sets `CARAPACE_*` and the carapace `PATH` entry. `fish-complete parse-output` is pure. `completion/external` is a deprecated shim for it. |
| `style` (mild) | Reads `$env.config.color_config`; works with Nushell's defaults. |
| root `mod.nu` | Aggregates config-dependent modules; needs out-of-repo lib dirs to parse. |

## Rules of thumb for new code

- Put pure logic in an abstract module (or a private helper) and keep the external call at the edge, so the logic
  can be tested without the dependency.
- Derive state locations from `$nu.data-dir`/`$nu.cache-dir` or XDG variables, never hard-coded home paths, so tests
  can redirect them.
- Avoid parse-time absolute imports (`use /abs/path`) in modules that others import: they make every importer
  fail to parse on other machines.
- When a module needs set-up at import time, make the `export-env` idempotent (re-`use` must not stack hooks or
  duplicate `PATH` entries).
