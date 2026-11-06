# Errors: codes derived from the raise site

Library code raises errors with `error raise` from the `error` module. The command derives a stable code from the
place it is called, so every error has an identity (`conf::dir::not_found`) without a hand-written code at each
site, and callers can catch by code. `help error raise` and the module header are the reference; this page covers
the format, the vocabulary, and the rules the derivation follows.

## Raising

```nushell
use error

export def dir [name: string]: nothing -> path {
  let dir: path = $nu.default-config-dir | path join $name
  if not ($dir | path exists) {
    error raise $"no config directory named '($name)'" --kind not_found --advice 'create it with `conf init`'
  }
  $dir
}
```

Raised from `conf/mod.nu`, this renders as

```
Error: conf::dir::not_found

  × no config directory named 'tools'
  help: create it with `conf init`
```

```
error raise <message> [--kind (-k) <kind>] [--advice (-a) <text>] [--labels <table>] [--code <code>]
```

| Flag | Meaning |
|---|---|
| `--kind` | The kind of failure, from the vocabulary below (default `internal`). An unknown kind raises `error::raise::invalid_argument`, labelled at the flag. |
| `--advice` | Rendered as the error's `help`: what to do about it. Empty text is left out. |
| `--labels` | `[{text, span}]` rows that point at source spans. With labels, `error raise` *returns a closure* instead of raising; call it with `do $in` at the raise site, so the spans render where they belong. |
| `--code` | Replaces the derived code entirely. `--code ''` raises without a code. |

Pipeline input (a caught error, or any error record) becomes the raised error's single `inner` error:
`try { open $path } catch {|e| $e | error raise $"could not read '($path)'" --kind io }`.

## The code

A code has the shape `<namespace>::<command>::<kind>`. Nothing is configured: each segment is read from the raise
site when the error is raised.

| Segment | Derived from | Examples |
|---|---|---|
| namespace | The raising file's path under the library root that contains it: directories joined with `::`, plus the file stem unless the file is `mod.nu`. The library roots are the `NU_LIB_DIRS` entries and the directory holding the `error` module. | `conf/mod.nu` → `conf`; `mods/local/mod.nu` → `mods::local`; `conf/machine.nu` → `conf::machine`; `env/from-bash.nu` → `env::from-bash` |
| command | The enclosing `def` (`export def`, `def --env`, `def --wrapped`, quoted or bare names), with spaces turned into `-`; in practice the last `def` line before the raise (see below). Omitted for `main` and when no `def` precedes the raise in the file. | `export def "win env"` → `win-env`; `export def main` → `<namespace>::<kind>` |
| kind | `--kind`, default `internal`. | `not_found` |

Fallbacks never fail a raise:

- Code that is not in a file (the REPL, `nu -c`) gets the namespace `nu` and no command: `nu::not_found`.
- A file outside every library root is named by its stem (`~/bin/deploy.nu` → `deploy`); a `mod.nu` there, and
  the library root's own `mod.nu`, by its directory.
- If anything unexpected happens during derivation, the code is `nu::<kind>`.

### How the raise site is found

The span of the `message` argument (`metadata $message`) locates the file that raised, through `view files`; the
file's path gives the namespace, and the file text before the span (`view span`) is scanned for the last `def`
line to give the command. The derivation runs only when an error is raised, reads nothing from disk (the engine
already holds every loaded file's text) and looks at one file.

The consequence: **write the message at the raise site**. A literal or an interpolation written in the `error
raise` call carries the span of that call. A message built in the same command (`let msg = $"…"`) still lies in
that command. A message returned by a helper, or stored in a constant, carries the span of *its* site, so the
derived command would be the helper's: pass `--code` in that case, or build the message where it is raised.

The command segment is an approximation too: the last line matching a `def` before the raise, not a parse. Three
shapes mislead it:

- a helper `def` nested inside the command body: a raise after it is attributed to the helper;
- a multi-line string literal that contains a `def …` line: attributed to that name;
- a raise outside any `def` that *follows* one in the file: an `export-env` block or an alias body
  (`export alias boom = do { error raise 'late' --kind conflict }`) placed after the defs is attributed to the last
  of them (`late::go::conflict` rather than `late::conflict`; before the first def it derives correctly).

Pass `--code` in the first two cases, or move the helper out of the command. For a raise in an `export-env` block
or an alias, pass `--code`: the section order puts the environment block after the definitions, so such a raise
nearly always follows a def. Nothing in the library has any of the three shapes today.

### The directive

A file can replace its path-derived namespace with a comment anywhere in it, in the style of
`# nu-lint-ignore-file:`:

```nushell
# error-namespace: conf
```

Use it only when a module genuinely needs a different root (a file that moved but keeps a public code, a module
split across directories). The command and kind segments are still derived.

## Kinds

The vocabulary is fixed (`$error.KINDS`); choose the kind by what the caller can do about the failure.

| Kind | Use for |
|---|---|
| `invalid_argument` | Bad input: a flag, value or combination the command does not accept; the default when the caller's input is wrong. |
| `not_found` | Something named does not exist: a file, directory, key, item, command or target. |
| `unsupported` | The operation is not available here: wrong operating system, platform or feature set. |
| `missing_dependency` | A required external program, module or configuration is absent (`bash` is not on `PATH`). |
| `external_failure` | An external program ran and failed. |
| `conflict` | The state clashes with the request: it already exists, is already running, is locked. |
| `io` | A filesystem or network operation failed (read, write, download). |
| `internal` | A bug or unexpected state in the library itself; the default kind. |

## Pipeline input at the raise site

`error raise` takes pipeline input, but uses it only when it is an error record (a record with `msg`, such as a
caught error): that becomes the new error's single `inner`. Any other input is ignored, so a raise may be the first
command of a block that receives pipeline input (`each`, `if` bodies, match arms) without binding `$in` first.
Inside `catch {|e| … }` the closure's `$in` is the caught error, so a raise there chains it as `inner`, which is
usually what you want.

## Message style

- Start lowercase, no trailing period: `no config directory named 'tools'`.
- Interpolated values go in single quotes: `$"unknown --return '($return)'"`.
- The message says what went wrong; what to do about it goes to `--advice`, not into the message.
- Name the thing, not the code path: `the profile could not be read`, not `read-profile failed`.

## Labels

Errors that should point at source spans use `--labels`. Because `error raise` then returns a closure, the raise
site stays in control of when and where the error is made:

```nushell
error raise 'this value is not a path' --kind invalid_argument --labels [{text: 'here' span: (metadata $value).span}] | do $in
```

The code is derived where the closure is made (the `error raise` call), not where it is run.

## Catching by code

The code is in `$e.details.code` of a caught error. Match on the kind, the namespace, or the whole code:

```nushell
try { conf dir tools } catch {|e|
  let code: string = $e.details.code? | default ''
  if ($code | str ends-with '::not_found') { mkdir ($nu.default-config-dir | path join tools) } else { $e | error raise 'could not open the tools directory' --kind io }
}
```

Builtin errors have Nushell's own codes (`nu::shell::…`), and `error make` without a code gives null, hence the
`default ''`: `=~` and `starts-with` reject null.

## Cost

Measured on Nushell 0.116.2-nightly.32 (`timeit`, 50 raises caught in a loop, median of 20 runs, 37 files
loaded), raising from modules of three sizes:

| Raise | 1.7 KB module | 15 KB module | 79 KB module |
|---|---|---|---|
| `error make --unspanned {msg: …}` | 11 µs | 11 µs | 11 µs |
| `error raise … --code …` (no derivation) | 31 µs | 30 µs | 32 µs |
| `error raise …` (derived) | 272 µs | 347 µs | 464 µs |

Of the derived cost, finding the file (`view files`) takes ~55 µs and the library roots ~40 µs regardless of
size; the rest scales with the file: fetching its text, the directive search, and the `def` scan (the 4 KB before
the site first, the whole prefix only for a longer command body). The derivation runs only on the error path; a
command that does not fail pays nothing.

When measuring raises yourself, `1..50 | each { try { … } }` pipes the counter into `error raise`; input that is
not an error record is ignored, so the loop times the raise itself.
