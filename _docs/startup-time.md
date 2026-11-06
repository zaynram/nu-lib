# Startup time

What importing the library costs a shell, how it is measured, and where the cost goes. The numbers are from
0.116.2-nightly.33 on the owner's laptop (WSL) on 2026-11-06; re-measure after a change to the barrel or to a module's
imports, and record the new reading here.

## Method

`$nu.startup-time` covers the whole boot (env.nu, config.nu, every autoload file) and does not register config
evaluation in the `--config … -e` mode, so the library's share is measured as process wall time:

```nushell
# wall time of one import, min of 7, in a throwaway HOME/XDG tree (a bare `nu --no-config-file -c null` is 8–11 ms of it)
let sandbox = {HOME: $h XDG_CONFIG_HOME: ($h | path join .config) XDG_DATA_HOME: ($h | path join .local share) XDG_CACHE_HOME: ($h | path join .cache)}
with-env $sandbox {
  1..7 | each { timeit { ^nu --no-config-file --login --interactive -I $root -c $"use ($root | to nuon) *; null" | complete } } | math min
}
```

Login + interactive is the owner's case (every guarded loader in the barrel's `export-env` runs). "Owner shape" adds
a `.nu` machine override in the sandbox's config directory and `WORK` pointing at a directory of 30 `git init`
repositories under `src/`; "first" is a fresh HOME (cold registry, cold override cache), "warm" the next start after
a two-second pause for the hydration job.

## Readings (ms of wall time per import; the ~10 ms bare shell is included)

| tree | plain `use` | login + interactive | owner shape: first / warm |
|---|---|---|---|
| main (before this initiative) | 53 | 53 | 54 / 54 |
| fix/review-3 (the finished stack: harness, errors, from-bash, machine config, use-colors, session, hydration, env parse, five review rounds) | 144 | 159 | 219 / 164 |

Measured on a quiet machine (load < 1) on 2026-11-06; earlier readings taken while review agents ran their suites
were 10–30 % higher and are not comparable.

The library's share of a login grew from roughly 53 ms to roughly 160 ms. Most of it is parse cost that cannot be
deferred (Nushell parses a `use` target at parse time; a job cannot import into the parent — `_docs/hydration.md`):
`conf` imports `validate` for the override's validation plus `edit`, `completion` and `path`; `pman/nightly.nu`
brings `std/log`, `error` and `reload`; `env` gained `from-bash` and `parse`; `session` is new. The runtime work that
used to happen at import is gone from the critical path: proj's workspace scan (isolated: a cold 30-repository
import 106 → 38 ms) and the override script's child `nu` plus validation (a cache hit saves ~12 ms per login); the
owner-shape "first" start still pays the cold override load, the cold registry's job spawn and the completers.

Per-module parse cost on the finished stack (plain `use <module>`, min of 5, ms over the 8 ms bare shell): conf 53,
pman 33, track 23, proj 22, mods 17, validate 12, test 12, env 12, hook 10, todo 8, time 6, path 5, log 5, link 4.
Inside the barrel each module is parsed once, so the barrel total (≈135 over bare) is well below the sum.

## Reading it

- Parse cost is the floor. The only ways down are fewer imports at boot: `conf` alone is a third of it (its
  `validate`/`edit`/`completion` imports), so validating the override in a child `nu` only when a file exists, or
  moving `conf dir/auto/find/prompt` out of the login path, would be the first candidates; stopping the barrel from
  exporting `pman` or `mods` and `use`-ing them on demand would be the next. The owner chose to keep `pman` and
  `mods` in the barrel (they are imported at boot anyway); the trade is recorded in the decision catalogs.
- Runtime work at import belongs in a background job with one atomic snapshot write (`_docs/hydration.md`); never
  add a scan, a child process or a network call to an `export-env` block.
- Measure before arguing: `timeit` for one run, `use std/bench; bench {…} {…} -n 10` for alternatives; the
  `_docs/data-shaping.md` tables hold the micro-benchmarks behind the data-shaping rules.
