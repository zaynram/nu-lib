# Background hydration

Some modules need data that is slow to compute (a workspace scan, a child `nu` evaluating a configuration script)
and used from the first prompt on. Computing it at import time puts the cost on every shell start; this document
describes the pattern the library uses instead, and when not to use it.

## The pattern: stale-while-revalidate with one atomic write

1. **One snapshot, one key.** The whole dataset is stored as a single value — one key in a `std-rfc/kv` universal
   table, or one `.nuon` file written to a temporary name and renamed into place. A reader loads it with one read
   and never sees a half-written state. Per-row writes from a background job are never used: `kv set --universal`
   costs ~0.5 ms per call, writers contend for SQLite's lock, and a job killed mid-way would leave a torn registry.
2. **Readers never block.** A missing snapshot yields defaults (an empty list, the built-in configuration); a stale
   snapshot is served as it is. Nothing a user types waits for hydration.
3. **Hydration runs in a job, in interactive shells only.** The module's `export-env` checks the snapshot's stamp
   and, when it is missing or stale, starts `job spawn --auto-kill --description '<module>: …' { … }`. The job does
   all the slow work and ends with exactly one write of the new snapshot plus its stamp (time, elapsed, and the
   fingerprint of the inputs it was computed from). A `hydrating` stamp written before the spawn lets a second shell
   started in the same minutes skip a duplicate job.
4. **Non-interactive shells do no import-time work.** A job dies with its process, so a `nu -c …` or a script would
   never see its result: readers in such shells compute synchronously only when no snapshot exists at all, and the
   explicit commands (`proj scan --force`, `conf machine-config --no-cache`) always run synchronously and rewrite the
   snapshot. In an interactive shell a reader that runs before the first job has finished sees the empty default
   (`proj list` is `[]` for a moment after the very first start on a machine).
5. **Staleness is decided by a fingerprint, with a TTL as the fallback.** The fingerprint is cheap to compute on
   every import (for `proj`, the modification times of the four kind directories under `$env.WORK`, ~0.3 ms; for
   `conf`, the override file's size and modification time — the file itself, a symlink is followed — plus the
   library root and the running `nu` version). The TTL (24 h for both) catches what the fingerprint cannot see: a
   remote URL edited inside a repository, a file or variable an override script reads. A fingerprint miss only
   needs the cheap part redone (new project directories inspected, missing ones dropped); a TTL miss inspects
   everything again. A command that changes the snapshot without inspecting anything (`proj scan --prune`) keeps the
   stamp it found, so the next import still sees what the rows were computed from.
6. **Observability.** `proj meta` reports the snapshot's `stamp` (with its age), the fingerprint it was taken from and
   whether a hydration job is running (`hydrating`: this shell's job, or another shell's fresh mark); while the very
   first scan of a workspace is still running it reports only `{hydrating: true}`. `conf machine-config --verbose`
   prints `cache = hit|miss|off|none`. A job that fails logs one warning through the `log` module and leaves the
   previous snapshot untouched.

## Where it is used

| Module | Snapshot | Hydration | Staleness |
|---|---|---|---|
| `proj` | kv table `proj`, key `snapshot`: `{stamp, last_scan, kinds}` | job at interactive import; `scan` in the foreground (it honours the same staleness rule; `--force` scans regardless) | fingerprint (kind directories' mtimes) or 24 h (then every project is inspected again) |
| `conf` | `$nu.cache-dir/nu-lib/machine-override.nuon`: the override file's checked record | none needed: a miss loads synchronously (the first login after a change) | the file's mtime and size (symlink followed), the library root and the `nu` version; a script's record also expires after 24 h |
| `completion/local` | none | — | the carapace runtime environment is recomputed per completion (cheaper than any staleness check) |
| `track` | none | — | event-driven (hooks); nothing is computed at import |

Measured on 0.116.2-nightly.33 (min of 5, wall time of `nu --no-config-file --login [--interactive] -c 'use <m>; null'`
over a 10 ms bare shell): `proj` with a 30-repository workspace and a cold registry 106 ms → 38 ms (warm 34 → 36 ms:
the snapshot read, the fingerprint and `use log`); `conf` with a `.nu` override: see `_docs/startup-time.md`.

## Why `--auto-kill`

No job outlives its process on this nightly. What `--auto-kill` changes is the interactive `exit`: without it, `exit`
with a running job refuses once (`nu::shell::background_jobs_running … Run exit again to kill all jobs`); with it,
`exit` is silent and kills the job. A hydration job is disposable — the atomic write means a killed job simply
leaves the old snapshot in place — so it is always spawned with `--auto-kill`.

## When not to use it

- Parse cost. `use` happens at parse time and a job cannot import into the parent scope: the cost of parsing a
  module is paid by every shell that imports it, hydration or not (`_docs/startup-time.md`).
- Work that is already event-driven (`track`'s hooks run when the prompt or the directory changes; nothing is
  computed at import).
- Small, static data (`conf`'s `.nuon` override loads in 0.1 ms; only the `.nu` form, which runs a child `nu`, is
  cached).
- Anything whose result must be exact at the next prompt. The pattern trades freshness for latency; a command that
  needs the current state runs the computation itself (`proj scan --force`).
