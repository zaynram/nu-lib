# `env parse`: environment variables from files, each read by the reader its file name selects.
#
# A submodule (re-exported by env/mod.nu) rather than a `def parse` in the module: a command named like a
# builtin, defined inside a module, shadows that builtin for every module parsed in its scope.

# ——— imports ——————————————————————————————————————————————————————————————————

use error
use from-bash.nu

# ——— constants ————————————————————————————————————————————————————————————————

# Files read with `from dotenv`, and with `from-bash`, by extension; bash scripts by basename.
const DOTENV_EXTENSIONS: list<string> = [env conf dotenv]
const BASH_EXTENSIONS: list<string> = [sh bash]
const BASH_NAMES: list<string> = ['.profile' '.bashrc' '.bash_profile' '.bash_login']
# A line a dotenv reader takes: blank, a comment, or an assignment (`export` allowed).
const DOTENV_LINE: string = r#'^\s*($|#|(export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=)'#
# A value only a shell gives meaning to: a leading `~`, `$(…)` (also `$((…))`) or backticks.
const SHELL_VALUE: string = r#'=\s*["']?(~|\$\(|`)'#

# ——— helpers ——————————————————————————————————————————————————————————————————

# The reader of a file by its name: `dotenv`, `bash`, or null when the name says nothing (`reader-of --guess`
# then decides from the content: the shebang, else the lines).
def reader-of [file: path --guess]: nothing -> oneof<nothing, string> {
  let name: string = $file | path basename
  let extension: string = $file | path parse | get extension
  if $name in $BASH_NAMES { return 'bash' }
  if $extension in $DOTENV_EXTENSIONS or $name starts-with '.env' { return 'dotenv' }
  if $extension in $BASH_EXTENSIONS { return 'bash' }
  if not $guess or $extension != '' { return null }
  let text: string = read-text $file
  if ($text | lines | first 1 | get --optional 0 | default '') =~ '^#!.*\b(ba)?sh\b' { return 'bash' }
  if ($text | check-lines | is-empty) { 'dotenv' } else { 'bash' }
}

# The lines a dotenv reader cannot take, with their numbers and why.
def check-lines []: string -> table<line: int, text: string, reason: string> {
  lines | enumerate | each {|l|
    if $l.item !~ $DOTENV_LINE {
      {line: ($l.index + 1) text: ($l.item | str trim) reason: 'is not KEY=VALUE'}
    } else if $l.item =~ $SHELL_VALUE {
      {line: ($l.index + 1) text: ($l.item | str trim) reason: 'needs a shell'}
    }
  } | compact
}

def read-text [file: path]: nothing -> string {
  try { open --raw $file } catch {|e| $e | error raise $"'($file)' could not be read" --kind io }
}

# The variables of one file, through the reader its name (or content) selects.
def read-file [file: path]: nothing -> record {
  match (reader-of $file --guess) {
    bash => { from-bash $file }
    dotenv => {
      let text: string = read-text $file
      let bad: table = $text | check-lines
      if ($bad | is-not-empty) {
        error raise $"'($file)' line ($bad.0.line) ($bad.0.reason): ($bad.0.text)" ...{
          kind: invalid_argument
          advice: 'a shell script: name it .sh, or read it with `env from-bash`'
        }
      }
      try { $text | from dotenv } catch {|e| $e | error raise $"'($file)' is not a valid .env file" --kind invalid_argument }
    }
    _ => {
      error raise $"'($file)': no reader for this file name" ...{
        kind: invalid_argument
        advice: $".env/.conf/.dotenv are parsed, .sh/.bash and ($BASH_NAMES | str join ', ') run in bash; a file without an extension goes by its content"
      }
    }
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Read environment variables from files, each read by the reader its name selects.
#
# `.env`, `.conf` (systemd's `environment.d`) and `.dotenv` files are parsed with the builtin `from dotenv`: `export
# KEY=value` is a plain `KEY`, blank and `#` comment lines (also trailing comments) are skipped, one pair of matching
# quotes around a value is removed, `$NAME`/`${NAME}` expand in unquoted and double-quoted values (to an earlier key
# of the file, else to `$env`, names ignoring case; an undefined name expands to nothing, `${NAME:-word}` gives
# `word`), single quotes keep a value literal, unquoted `\$` is a backslash and an expansion, double-quoted `\$` is a
# literal dollar. A line that is not an assignment, or a value only a shell gives meaning to (`$(…)`, backticks,
# `$((…))`, a leading `~`), is an error naming the line: such a file is a shell script. `.sh`/`.bash` files and
# `.profile`, `.bashrc`, `.bash_profile`, `.bash_login` run through `env from-bash` (their merged changes). A file
# with no extension goes by its shebang, else by its lines (all assignments: dotenv; otherwise bash); any other name
# is an error. A directory reads the files it knows how to read, in lexical order. Several paths merge in order,
# later values win, and every file sees the values of the files before it (as systemd resolves `environment.d`).
# Returns a record of the variables, or a `key`/`value` table with `--no-transpose`; `--load` loads them with
# `load-env`, which converts PATH and every variable with an `ENV_CONVERSIONS` entry.
export def --env main [
  ...paths: path@_files # Files or directories to read, in order; `.env` when none is given
  --load (-l) # Load the variables into the process environment
  --no-transpose (-n) # Return the variables as a table instead of a record
]: nothing -> oneof<table<key: string, value: string>, record> {
  let targets: list<path> = if ($paths | is-empty) { ['.env'] } else { $paths }
  let files: list<path> = $targets | each {|p|
    if not ($p | path exists) { error raise $"not found: '($p)'" --kind not_found }
    if ($p | path type) == dir {
      glob --no-dir --no-symlink ($p | path join '*') | sort | where (reader-of $it) != null
    } else { [$p] }
  } | flatten
  # A fold over a handful of files: each one is read with the previous results in scope (tiny accumulator).
  let vars: record = $files | reduce --fold {} {|file acc| $acc | merge (with-env $acc { read-file $file }) }
  if $load { load-env $vars }
  if $no_transpose { $vars | transpose key value } else { $vars }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _files []: nothing -> list<path> { '.env' | commandline complete --type=path }
