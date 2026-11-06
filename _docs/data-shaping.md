# Data shaping: measured idioms

The rules in `CLAUDE.md` ("Data shaping and performance") come from these measurements. Re-run them when a
nightly changes the picture; Nushell's internals move fast.

Measured 2026-11-06 on Nushell 0.116.2-nightly.32 with `std/bench` (`-n 10`, mean ± std, ms), over a
5,000-entry record (`k1: 1 … k5000: 5000`) or a 5,000-element list of two-element lists.

| Task | Approach | Mean | Std |
|---|---|---|---|
| Iterate a record into a list | `items {\|k v\| …}` | 4.1 | 0.05 |
| | `transpose k v \| each {…}` | 28.2 | 0.56 |
| | `columns \| each {\|k\| … get $k …}` | 28.9 | 0.82 |
| Map a record's values | `items {\|k v\| [$k …]} \| into record` | 24.3 | 0.36 |
| | `transpose k v \| update v {…} \| transpose --header-row --as-record` | 49.9 | 1.05 |
| | `transpose k v \| reduce --fold {} {\|r acc\| $acc \| insert …}` | 625.0 | 53.0 |
| Filter a record's entries | `items {… if keep { [$k $v] }} \| compact \| into record` | 13.4 | 0.13 |
| | `transpose k v \| where … \| transpose --header-row --as-record` | 35.6 | 0.33 |
| | `reject ...($rec \| columns \| where …)` | 59.5 | 2.05 |
| Flatten per-item lists | `each --flatten {…}` | 2.5 | 0.02 |
| | `each {…} \| flatten` | 2.3 | 0.03 |
| | `reduce --fold [] {\|p acc\| $acc \| append $p}` | 1037.0 | 75.7 |

`items` feeding `into record` costs the same whichever shape it returns: `[$k $v]` pairs 26.4 ± 0.6 ms,
single-key records `{$k: $v}` 26.6 ± 0.2 ms (5,000 entries); the closure calls dominate. Both resolve duplicate
keys to the later value; a pair list errors on any element that is not exactly two items.

Accumulating with `mut` instead of `reduce` (20,000 items, `timeit`, single run): `mut xs ++= [...]` in a `for`
loop took 1,375 ms against 8,607 ms for `reduce` + `append` and 20 ms for `each`. Mutation softens the quadratic
cost but does not remove it; collecting with `each`/`items` does.

Semantics checked alongside (same nightly):

- `{a: 1, b: 2} | rotate` → `[[column0 column1]; [1 a] [2 b]]` (values first); `rotate key value` names the
  value column `key`; `rotate --ccw` gives keys first but in reverse order (`b`, then `a`).
- `[[a 1] [b 2]] | into record` → `{a: 1, b: 2}` (pairs). On a table `into record` merges the rows, later rows
  winning: `[{a: 1} {b: 2}] | into record` → `{a: 1, b: 2}`, `[[k v]; [a 1] [b 2]] | into record` → `{k: b, v: 2}`.
  The intent is collapsing a single-row table, e.g. `"k=v" | parse "{key}={value}" | into record` →
  `{key: k, value: v}`.
- `[[k v]; [a 1] [b 2]] | transpose --header-row --as-record` → `{a: 1, b: 2}`.
