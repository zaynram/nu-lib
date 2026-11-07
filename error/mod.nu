# Helpers for raising errors with codes derived from the raise site (see _docs/errors.md).

# When any `labels` are detected, `error raise` returns a closure instead of raising, intentionally:
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.
# nu-lint-ignore-file: missing_in_type
# (`raise` deliberately accepts any pipeline input: an error record is chained as `inner`, anything else is ignored)

# ——— constants —————————————————————————————————————————————————————————————————

# The kinds an error code may end in (see _docs/errors.md for when to use each).
export const KINDS: list<string> = [
  invalid_argument
  not_found
  unsupported
  missing_dependency
  external_failure
  conflict
  io
  internal
]

# The library root this module belongs to: the directory holding the `error` module.
const ROOT: path = path self ..
# The namespace of code that is not in a file (the REPL, `nu -c`).
const NO_FILE: string = 'nu'
# A `def` line: optional `export`, flags such as `--env`/`--wrapped`, then a quoted or bare name.
const DEF: string = r#'(?m)^\s*(?:export\s+)?def\s+(?:--\w+\s+)*(?:"(?P<q>[^"]+)"|'(?P<s>[^']+)'|(?P<b>[^\s\[]+))'#
# The per-file override `# error-namespace: <ns>`.
const DIRECTIVE: string = r##'(?m)^\s*#\s*error-namespace:\s*(?P<ns>\S+)'##
# An absolute path (Unix or Windows).
const ABSOLUTE: string = r#'^(?:/|[A-Za-z]:[\\/])'#
# The bytes before the raise site that are searched first for its `def` line; a longer command body falls back to
# searching everything before the site.
const WINDOW: int = 4096

# ——— helpers ———————————————————————————————————————————————————————————————————

# The namespace and command of the raise site whose message has the span `span`.
#
# Code outside a file (REPL, `nu -c`) gets the namespace `nu` and no command; a raise outside any `def` has no
# command either.
def site [span: record<start: int, end: int>]: nothing -> record<namespace: string, command: oneof<nothing, string>> {
  # Files are listed in load order with increasing offsets, so the last one starting at or before the span holds it.
  let file: oneof<nothing, record> = view files | where start <= $span.start | last
  # Files on disk are listed by absolute path; `source`, `repl_entry #1` and the virtual `std/…` files are not.
  if $file == null or $file.filename !~ $ABSOLUTE { return {namespace: $NO_FILE command: null} }
  let text: string = view span $file.start $file.end
  {
    # A module imported by a relative path is listed with the `..` segments of that path.
    namespace: (namespace $text ($file.filename | path expand --no-symlink))
    command: (command ($text | str substring --utf-8-bytes 0..<($span.start - $file.start)))
  }
}

# The namespace of a file: its directive, or its path under the library root that contains it.
#
# Directories are joined with `::`, the stem is added unless it is `mod`; a file at the root of the library (or
# outside every library root) is named by its stem, the root's own `mod.nu` by the root directory.
def namespace [text: string file: path]: nothing -> string {
  let directive: oneof<nothing, string> = if $text =~ 'error-namespace:' {
    $text | parse --regex $DIRECTIVE | get $.0?.ns?
  }
  if $directive != null { return $directive }
  let root: oneof<nothing, string> = roots
    | where $file starts-with ($it | path join '')
    | sort-by --reverse { str length }
    | first
  let relative: string = if $root == null { $file | path basename } else { $file | path relative-to $root }
  let parsed: record = $relative | path parse
  [...($parsed.parent | path split) (if $parsed.stem != mod { $parsed.stem })]
  | compact --empty
  | default [($file | path dirname | path basename)] --empty
  | str join '::'
}

# The library roots: `$NU_LIB_DIRS`, `$env.NU_LIB_DIRS` (a list, or PATH-like text inherited from a parent
# process) and the root this module belongs to, expanded.
def roots []: nothing -> list<string> {
  let inherited: any = $env.NU_LIB_DIRS? | default []
  let from_env: list = if ($inherited | describe) == string { $inherited | split row (char esep) } else { $inherited }
  [...$NU_LIB_DIRS ...$from_env $ROOT] | each { path expand --no-symlink }
}

# The command name of the last `def` before the raise site (spaces become `-`), or null for `main` or no `def`.
def command [before: string]: nothing -> oneof<nothing, string> {
  let size: int = $before | str length --utf-8-bytes
  let def: oneof<nothing, record> = if $size <= $WINDOW {
    last-def $before
  } else {
    last-def ($before | str substring --utf-8-bytes ($size - $WINDOW).. | after-first-line) | default { last-def $before }
  }
  let name: oneof<nothing, string> = $def | each { values | compact --empty | first }
  if $name == null or $name == main { return null }
  $name | str trim | str replace --all ' ' '-'
}

# The last `def` line of `text` as its match (`q`, `s` or `b`: a double-quoted, single-quoted or bare name), or null.
def last-def [text: string]: nothing -> oneof<nothing, record> {
  $text | parse --regex $DEF | last
}

# The text after its first line, which a cut into the middle of the file may have left partial.
def after-first-line []: string -> string {
  let text: string;
  let newline: int = $text | str index-of --utf-8-bytes (char newline)
  if $newline < 0 { '' } else { $text | str substring --utf-8-bytes ($newline + 1).. }
}

# The code for a raise site and kind.
def derive [span: record<start: int, end: int> kind: string]: nothing -> string {
  let site: record = try { site $span } catch { {namespace: $NO_FILE command: null} }
  [$site.namespace $site.command $kind] | compact | str join '::'
}

# ——— definitions ———————————————————————————————————————————————————————————————

# The keys `raise --with` takes: the fields of `error make` (the message is the argument) and `kind`.
const WITH_KEYS: list<string> = [kind code help url label labels inner src]

# Raise the closure that `raise` returns when it has labels, in the caller's scope (`raise … {label} | throw`).
export def throw []: closure -> error { do --capture-errors $in }

# Raise an error whose code is derived from the raise site: `<namespace>::<command>::<kind>`.
#
# The `message` argument is used for introspection so it should be passed as a literal at the call site.
# ---
#
# The `<namespace>` is derived intrinsically for sibling modules from path of the caller.
# It can be overridden via a comment directive in the form `# error-namespace: <ns>`.
#
## Details
# `--with` takes the fields of `error make` (`code`, `help`, `url`, `label`, `labels`, `inner`, `src`) plus `kind`,
# and wins over the flags: `kind` replaces `--kind`, `code` replaces the derived code (`code: ''` raises without
# one). Any other key (`advice` is `help`) is an `error::raise::invalid_argument` error rather than silently lost.
#
## Input Behavior
# Pipeline input is accepted and untyped, but only error records are kept, with dynamic unwrapping for chains:
# a caught error contributes its `details`, an error record itself, and a record holding only `inner` its first
# inner error. If any error records are detected this way, they will be used as the inner for the new error.
#
## Output Behavior
# Raises the error unspanned when no `labels` are provided.
# Returns a closure for raising from the caller scope otherwise.
# * This module exports a `throw` method that can make this case more readable (see the examples)
@category core
@example 'raise an error' { raise 'uh oh' --kind=internal --with={help: 'try again'} }
@example 'raise an error with labels' {
  let v = version | get $.version | into semver
  let r = '>=1.0.0' | into semver-range
  if $r not-has $v {
    raise 'version is outside the accepted range' --kind=unsupported {
      text: version
      span: (metadata $v).span
    } {
      text: range
      span: (metadata $r).span
    } | throw
  }
}
export def raise [
  message: string
  # Error message to include in the rendered output (lowercase start, no trailing period)
  --kind (-k): string@$KINDS = internal
  # The kind of failure, from `$error.KINDS`
  --with (-w): oneof<record<help: string>, record<code: string>, record> = {}
  # Error details as passed directly to `error make` (prioritized over flags)
  ...labels: record<text: string, span: record>
  # Labels to include in the error output
]: any -> oneof<error, closure> {
  # Bound first: `raise` may be the first command of a block that receives input.
  let cause: list<any> = append [] | each {|it|
      if ($it | describe) !~ '^record' {
        null
      } else if $it has details {
        $it.details
      } else if $it has msg {
        $it
      } else if $it has inner {
        $it.inner | first
      }
    }
  let unknown: list<string> = $with | columns | where $it not-in $WITH_KEYS
  if $unknown != [] {
    error make {
      msg: $"unknown --with key '($unknown | first)'"
      code: 'error::raise::invalid_argument'
      help: $"--with takes ($WITH_KEYS | str join ', ') \(a remedy is `help`)"
      label: {text: 'these details' span: (metadata $with).span}
    }
  }
  let kind: string = $with.kind? | default $kind
  if $kind not-in $KINDS {
    error make {
      msg: $"unknown error kind '($kind)'"
      code: 'error::raise::invalid_argument'
      label: {
        text: $"one of ($KINDS | str join ', ')"
        span: (metadata $kind).span
      }
    }
  }
  # The span is taken here, not in the closure: a captured variable reports the span of its capture site.
  let span: record = metadata $message | get $.span

  # Not `flatten`: it would also flatten each label's `span` record into `start`/`end` columns.
  let labels: list<record> = [$with.label?]
    | compact
    | append ($with.labels? | default [])
    | append $labels
  let count: int = $labels | length

  let details: record = $with
    | reject --optional $.kind
    | default { derive $span $kind } $.code
    | upsert $.msg $message
    | upsert $.inner { append $cause }
    | match $count {
      0 => ()
      1 => (upsert $.label ($labels | first) | reject $.labels?)
      _ => (upsert $.labels $labels | reject $.label?)
    } | compact --empty

  match $count {
    0 => { error make --unspanned $details }
    _ => {|| error make $details }
  }
}
