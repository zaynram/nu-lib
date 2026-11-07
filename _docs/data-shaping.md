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

Nightly 0.116.2-nightly.33 adds `record each` and `record where` (same closure contract as `items`: return a record,
a `[k v]` pair, or null to drop). Over the 5,000-field record, mapping with `record each {|k v| {$k: ($v * 2)} }`
took 7.7 ms against 54 ms for `items … | into record` in the same run, and filtering with
`record where {|k v| $v mod 2 == 0 }` 5.4 ms against 16.2 ms for `items … | compact | into record`; the results are
identical. A row condition (`record where value > 1`) sees `{key, value}` rows.

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

## Parallelism, state, and type dispatch

Measured on the same nightly (`std/bench`, µs or ms as labelled).

`par-each` pays a fixed cost of roughly 0.9 ms per call (thread-pool dispatch) before any work happens:

| Items (trivial work: `str upcase`) | `each` | `par-each --keep-order` |
|---|---|---|
| 5 | 11 µs | 923 µs |
| 50 | 53 µs | 880 µs |
| 500 | 372 µs | 913 µs |
| 5,000 | 3,740 µs | 3,293 µs |

In the library, swapping every `par-each` in `validate`/`types` for `each` made `validate rules` on a small
document 8× faster (19.8 → 2.5 ms); only the per-row loop over a 200-row table benefited from parallelism
(32 ms parallel vs 39 ms sequential).

Writes to a shared store must not be parallel. `std-rfc/kv --universal` is SQLite, and concurrent writers contend
for its lock (and can leave inconsistent rows):

| 200 projects into kv | ms |
|---|---|
| `par-each { kv set --universal … }` | 8,659 |
| `each { kv set --universal … }` | 105 |
| one `kv set --universal` of the whole table | 0.8 |
| 200 × `kv get` vs 1 × `kv get` of the whole table | 99 vs 1.1 |

`describe` walks the whole value: 6.6 ms for a 20,000-row table (`describe --detailed`: 115 ms), against 7 µs for
`first | describe` and 4 µs on a scalar. Type dispatch with `match ($in | describe)` is free for scalars and
records but scales with the size of lists and tables.

`glob` compiles its `--exclude` patterns on every call: a 50-pattern exclude list added ~14 ms per call over
`~/.config`. A one-level `glob <dir>/*` and `ls <dir> | where type == dir` cost about the same (1.6 vs 1.1 ms for
300 entries).
