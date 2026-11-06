# Helpers for raising errors with codes derived from the raise site (see _docs/errors.md).
#
# `error raise` derives the code `<namespace>::<command>::<kind>` by introspection: the span of its `message`
# argument locates the file that raised it (`view files`), the file's path under the library root gives the
# namespace, and the enclosing `def` gives the command. The message must therefore be written at the raise site;
# `--code` is the escape hatch when it cannot be. The enclosing `def` is approximated by the last `def` line before
# the raise, so a helper `def` nested in the command body, or a multi-line string literal holding a `def …` line,
# names that `def` instead: pass `--code` where either occurs (nothing in the library does today).
#
# With `--labels`, `error raise` returns a closure instead of raising, intentionally:
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.
# nu-lint-ignore-file: missing_in_type
# (`raise` deliberately accepts any pipeline input: an error record is chained as `inner`, anything else is ignored)

# ——— constants —————————————————————————————————————————————————————————————————

# The kinds an error code may end in (see _docs/errors.md for when to use each).
export const KINDS: list<string> = [
  invalid_argument not_found unsupported missing_dependency external_failure conflict io internal
]

# The library root this module belongs to: the directory holding the `error` module.
const ROOT: path = path self ..
# The namespace of code that is not in a file (the REPL, `nu -c`).
const NO_FILE: string = 'nu'
# A `def` line: optional `export`, flags such as `--env`/`--wrapped`, then a quoted or bare name.
const DEF: string = r#'(?m)^\s*(?:export\s+)?def\s+(?:--\w+\s+)*(?:"(?P<q>[^"]+)"|'(?P<s>[^']+)'|(?P<b>[^\s\[]+))'#
# The per-file override `# error-namespace: <ns>`.
const DIRECTIVE: string = r#'(?m)^\s*#\s*error-namespace:\s*(?P<ns>\S+)'#
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
  let file: oneof<nothing, record> = view files | where start <= $span.start | last 1 | get $.0?
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
def namespace [text: string, file: path]: nothing -> string {
  let directive: oneof<nothing, string> = if $text =~ 'error-namespace:' {
    $text | parse --regex $DIRECTIVE | get $.0?.ns?
  }
  if $directive != null { return $directive }
  let root: oneof<nothing, string> = roots
    | where {|r| $file | str starts-with ($r | path join '') }
    | sort-by --reverse { str length }
    | get $.0?
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
  let name: oneof<nothing, string> = $def | each { values | compact --empty | get $.0? }
  if $name == null or $name == main { return null }
  $name | str trim | str replace --all ' ' '-'
}

# The last `def` line of `text` as its match (`q`, `s` or `b`: a double-quoted, single-quoted or bare name), or null.
def last-def [text: string]: nothing -> oneof<nothing, record> {
  $text | parse --regex $DEF | last 1 | get $.0?
}

# The text after its first line, which a cut into the middle of the file may have left partial.
def after-first-line []: string -> string {
  let text: string = $in
  let newline: int = $text | str index-of --utf-8-bytes (char newline)
  if $newline < 0 { '' } else { $text | str substring --utf-8-bytes ($newline + 1).. }
}

# The code for a raise site and kind.
def derive [span: record<start: int, end: int>, kind: string]: nothing -> string {
  let site: record = try { site $span } catch { {namespace: $NO_FILE command: null} }
  [$site.namespace $site.command $kind] | compact | str join '::'
}

# The kinds, for completion.
def kinds []: nothing -> list<string> { $KINDS }

# ——— definitions ———————————————————————————————————————————————————————————————

# Raise an error whose code is derived from the raise site: `<namespace>::<command>::<kind>`.
# ---
# The namespace is the raising file's path under the library root (`conf`, `mods::local`, `env::from-bash`), or
# its `# error-namespace: <ns>` directive; the command is the enclosing `def` (spaces become `-`; omitted for
# `main`); code outside a file (REPL, `nu -c`) gets `nu`. Write the message at the raise site: its span is what
# locates the file. `--code` replaces the derived code; `--code ''` raises without one.
#
# Raises the error unspanned when `--labels` is empty; returns a closure that raises it (`| do $in`) otherwise.
# An error record piped in (e.g. a caught error: a record with `msg`) becomes the error's single `inner` error; any
# other pipeline input is ignored, so a raise may sit first in a block that receives input. Empty `--code` and
# `--advice` values are left out. An unknown kind raises `error::raise::invalid_argument`.
@category core
export def raise [
  message: string # Error message to include in the rendered output (lowercase start, no trailing period)
  --kind (-k): string@kinds = internal # The kind of failure, from `$error.KINDS`
  --advice (-a): string # Suggestions or advice on how to avoid or remedy the error
  --labels: table<text: string, span: record> = [] # Labels to include in the error output
  --code: string # The full code, instead of the derived one
]: any -> oneof<error, closure> {
  let input: any = $in
  let cause: any = if ($input | describe) starts-with record and ($input has msg) { $input }
  if $kind not-in $KINDS {
    error make {
      msg: $"unknown error kind '($kind)'"
      code: 'error::raise::invalid_argument'
      labels: [{text: $"one of ($KINDS | str join ', ')" span: (metadata $kind | get span)}]
    }
  }
  # The span is taken here, not in the closure: a captured variable reports the span of its capture site.
  let span: record = metadata $message | get span
  let code: string = $code | default { derive $span $kind }
  let details: record = {msg: $message code: $code labels: $labels inner: ($cause | append []) help: $advice}
    | compact --empty
  if $labels == [] { error make --unspanned $details } else { return {|| error make $details } }
}
