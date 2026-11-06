# Startup time

What importing the library costs a shell, how it is measured, and where the cost goes. The numbers are from
0.116.2-nightly.33 on the owner's laptop (WSL) on 2026-11-06; re-measure after a change to the barrel or to a module's
imports, and record the new reading here.

## Method

`$nu.startup-time` covers the whole boot (env.nu, config.nu, every autoload file) and does not register config
evaluation in the `--config … -e` mode, so the library's share is measured as process wall time:

```nushell
# min of 7, in a throwaway HOME/XDG tree, minus a bare `nu -c null` (8–11 ms)
1..7 | each { timeit { ^nu --no-config-file --login --interactive -I <root> -c 'use <root> *; null' | complete } } | math min
```

Login + interactive is the owner's case (every guarded loader in the barrel's `export-env` runs). "Owner shape" adds
a `.nu` machine override and `WORK` holding 30 git repositories; "first" is a fresh HOME (cold registry, cold override
cache), "warm" the next start. The script lives in the session runbook; the table is what it printed.

## Readings (ms, bare nu subtracted elsewhere; wall times here include the ~10 ms bare shell)

| tree | plain `use` | login + interactive | owner shape: first / warm |
|---|---|---|---|
| main (before this initiative) | 55 | 55 | 71 / 55 |
| after the test harness, errors, from-bash, machine config, use-colors (round-2 stack) | 127 | 132 | 252 / 169 |
| + session, proj snapshot/job, conf override cache (feat/hydration) | 132 | 145 | 234 / 157 |

The library's share of a login grew from roughly 55 ms to roughly 145 ms. Half of that is parse cost that cannot be
deferred (Nushell parses a `use` target at parse time; a job cannot import into the parent — `_docs/hydration.md`):
`conf` imports `validate` for the override's validation, `pman/nightly.nu` brings `std/log`, `error` and `reload`,
`env` gained `from-bash` and `parse`, `session` is new. The other half was runtime work at import, which hydration
moved off the critical path: proj's workspace scan (isolated: a cold 30-repository import 106 → 38 ms) and the
override script's child `nu` plus validation (a cache hit saves ~12 ms per login).

Per-module parse cost (plain `use <module>`, min of 3, ms over the bare shell, feat/hydration): conf 53, pman 39,
proj 29–35, track 31, mods 26, test 19, validate 13–17, env 14, todo 14, hook 14, time 9, log 8. Inside the barrel
each module is parsed once, so the barrel total is well below the sum.

## Reading it

- Parse cost is the floor. The only ways down are fewer imports at boot: stop exporting `pman` (the whole
  conf/nightly chain) or `mods` from the barrel and `use` them on demand, or make `conf` validate the override in
  the child process only when a file exists. The owner chose to keep `pman` and `mods` in the barrel (they are
  imported at boot anyway); the trade is recorded in the decision catalogs.
- Runtime work at import belongs in a background job with one atomic snapshot write (`_docs/hydration.md`); never
  add a scan, a child process or a network call to an `export-env` block.
- Measure before arguing: `timeit` for one run, `use std/bench; bench {…} {…} -n 10` for alternatives; the
  `_docs/data-shaping.md` tables hold the micro-benchmarks behind the data-shaping rules.
