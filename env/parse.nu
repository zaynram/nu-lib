# `env parse`: environment variables from files, each read by the reader its file name selects.
#
# A submodule (re-exported by env/mod.nu) rather than a `def parse` in the module: a command named like a
# builtin, defined inside a module, shadows that builtin for every module parsed in its scope.

# ——— imports ——————————————————————————————————————————————————————————————————

use error
use from-bash.nu

# ——— constants ————————————————————————————————————————————————————————————————

# Files read with `from dotenv`, and with `from-bash`, by extension; bash scripts by basename (`.envrc` is direnv's
# bash script: a basename is checked before the `.env` prefix rule).
const DOTENV_EXTENSIONS: list<string> = [env conf dotenv]
const BASH_EXTENSIONS: list<string> = [sh bash]
const BASH_NAMES: list<string> = ['.envrc' '.profile' '.bashrc' '.bash_profile' '.bash_login']
# An assignment as `from dotenv` takes it (`export` allowed; a key is anything but whitespace, `=` and `#`), with
# its value as written.
const ASSIGNMENT: string = r#'^\s*(?:export\s+)?(?<key>[^\s=#]+)\s*=\s*(?<raw>.*)$'#
# What only a shell gives meaning to, anywhere in a written value: `$(…)` (also `$((…))`) or a backtick.
const SHELL_VALUE: string = r#'\$\(|`'#
# Variables Nushell manages itself: a bash file's `cd` changes them and `load-env` refuses them (as `from-bash
# --load` leaves them out).
const UNLOADABLE: list<string> = [PWD OLDPWD FILE_PWD CURRENT_FILE]
const SHELL_ADVICE: string = 'a shell script: name it .sh, or read it with `env from-bash`'

# ——— helpers ——————————————————————————————————————————————————————————————————

# The reader of a file by its name: `dotenv`, `bash`, or null when the name says nothing (`read-file` then goes by
# the content of a file without an extension).
def reader-of [file: path]: nothing -> oneof<nothing, string> {
  let name: string = $file | path basename
  let extension: string = $file | path parse | get extension
  if $name in $BASH_NAMES { return 'bash' }
  if $extension in $DOTENV_EXTENSIONS or $name starts-with '.env' { return 'dotenv' }
  if $extension in $BASH_EXTENSIONS { return 'bash' }
}

def read-text [file: path]: nothing -> string {
  try { open --raw $file } catch {|e| $e | error raise $"'($file)' could not be read" --kind io }
}

# The position of the quote that closes a value opened with `quote`, or null when the line does not close it (a
# `\"` does not close a double-quoted value).
def closing-index [quote: string]: string -> oneof<nothing, int> {
  if $quote == "'" {
    str index-of "'" | if $in < 0 { null } else { $in }
  } else {
    parse --regex r#'^(?<before>(?:[^"\\]|\\.)*)"'# | get --optional $.0?.before | if $in == null { null } else { str length }
  }
}

# The lines of dotenv text as written, each `skip` (blank or comment), `assignment` (with `key`, the opening `quote`
# or '' and the `body`: the value up to its closing quote, else up to a trailing comment), `continuation` (inside a
# quoted multi-line value) or `junk` (nothing a dotenv file can hold, with its `text`); `index` is the line number
# from 0. The state carried between lines is the quote a value left open ('' for none).
def walk-lines []: string -> list<record> {
  lines | enumerate | generate {|l, open|
    let line: string = $l.item
    if $open != '' {
      {out: {index: $l.index kind: continuation} next: (if ($line | closing-index $open) == null { $open } else { '' })}
    } else if $line =~ '^\s*($|#)' {
      {out: {index: $l.index kind: skip} next: ''}
    } else {
      let m: oneof<nothing, record> = $line | parse --regex $ASSIGNMENT | get $.0?
      if $m == null {
        {out: {index: $l.index kind: junk text: ($line | str trim)} next: ''}
      } else if ($m.raw | str substring 0..<1) in ['"' "'"] {
        let quote: string = $m.raw | str substring 0..<1
        let rest: string = $m.raw | str substring 1..
        let close: oneof<nothing, int> = $rest | closing-index $quote
        let body: string = if $close == null { $rest } else { $rest | str substring 0..<$close }
        {out: {index: $l.index kind: assignment key: $m.key quote: $quote body: $body} next: (if $close == null { $quote } else { '' })}
      } else {
        let body: string = $m.raw | str replace --regex '\s+#.*$' ''
        {out: {index: $l.index kind: assignment key: $m.key quote: '' body: $body} next: ''}
      }
    }
  } ''
}

# What dotenv text holds: `{vars}`, or why it is not a dotenv file: `{line, text}` (the first line that is not
# blank, a comment, an assignment or the continuation of a quoted value), `{key}` (a value only a shell gives
# meaning to, as written: `$(…)` or a backtick in an unquoted or double-quoted value, or an unquoted leading `~`)
# or `{inner}` (`from dotenv` failed, and no line explains why).
def dotenv-verdict []: string -> record {
  let text: string = $in
  let parsed: record = try { {vars: ($text | from dotenv)} } catch {|e| {inner: $e} }
  let walk: list<record> = $text | walk-lines
  if $parsed has inner {
    let bad: oneof<nothing, record> = $walk | where kind == junk | get $.0?
    return (if $bad == null { $parsed } else { {line: ($bad.index + 1) text: $bad.text} })
  }
  # The written value decides (the last assignment of a key wins, as in `from dotenv`): quotes say what a shell
  # would have done, and the expansion `from dotenv` performed is not a shell's.
  let shell: oneof<nothing, string> = $walk
    | where kind == assignment
    | reverse
    | uniq-by key
    | where quote != "'" and (($it.quote == '' and ($it.body | str starts-with '~')) or $it.body =~ $SHELL_VALUE)
    | get $.0?.key
  if $shell == null { $parsed } else { {key: $shell} }
}

# The exported changes of a bash script (`from-bash --return env`), less the variables Nushell manages itself: a
# variable the script unsets is null, one it empties is ''.
def from-bash-text []: string -> record {
  from-bash --return env --keep-empty | reject --optional ...$UNLOADABLE
}

# The variables of one file, through the reader its name selects; a file without an extension goes by its
# content: a `sh`/`bash` shebang, or anything a dotenv file cannot hold, means bash.
def read-file [file: path]: nothing -> record {
  let reader: oneof<nothing, string> = reader-of $file
  if $reader == null and ($file | path parse | get extension) != '' {
    error raise $"'($file)': no reader for this file name" ...{
      kind: invalid_argument
      advice: $".env/.conf/.dotenv are parsed, .sh/.bash and ($BASH_NAMES | str join ', ') run in bash; a file without an extension goes by its content"
    }
  }
  let text: string = read-text $file
  if $reader == 'bash' { return ($text | from-bash-text) }
  if $reader == null and ($text | lines | get --optional 0 | default '') =~ '^#!.*\b(ba)?sh\b' {
    return ($text | from-bash-text)
  }
  let verdict: record = $text | dotenv-verdict
  # Only a named dotenv file is held to the grammar: an unnamed one that breaks it is a shell script.
  if $reader == null and ($verdict has line or $verdict has key) { return ($text | from-bash-text) }
  match $verdict {
    {vars: $vars} => $vars
    {line: $n text: $line} => {
      error raise $"'($file)' line ($n) is not KEY=VALUE: ($line)" ...{
        kind: invalid_argument
        advice: $SHELL_ADVICE
      }
    }
    {key: $key} => {
      error raise $"'($file)': the value of '($key)' needs a shell" ...{
        kind: invalid_argument
        advice: $SHELL_ADVICE
      }
    }
    {inner: $e} => { $e | error raise $"'($file)' is not a valid .env file" --kind invalid_argument }
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Read environment variables from files, each read by the reader its name selects.
#
# `.env`, `.conf` (systemd's `environment.d`) and `.dotenv` files are parsed with the builtin `from dotenv`: `export
# KEY=value` is a plain `KEY`, blank and `#` comment lines (also trailing comments) are skipped, a quoted value may
# span lines, one pair of matching quotes around a value is removed, `$NAME`/`${NAME}` expand in unquoted and
# double-quoted values (to an earlier key of the file, else to `$env`, names ignoring case; an undefined name
# expands to nothing, `${NAME:-word}` gives `word`), single quotes keep a value literal, unquoted `\$` is a
# backslash and an expansion, double-quoted `\$` is a literal dollar. A line that is not an assignment is an error
# naming the line, and a value only a shell gives meaning to (`$(…)`, `$((…))` or a backtick anywhere in an
# unquoted or double-quoted value, an unquoted leading `~`) is an error naming the key: such a file is a shell
# script. `.sh`/`.bash` files and `.envrc`, `.profile`, `.bashrc`, `.bash_profile`, `.bash_login` run through `env
# from-bash`: their exported changes count, a variable they unset is removed from the result, one they empty
# stays empty, and a `cd` (PWD, OLDPWD) is left out. A file with no extension goes by its shebang, else by its
# content (a dotenv file: parsed; anything else: bash); any other name is an error. A directory reads the files
# it knows how to read by name, in lexical order; a symlink to a file counts, one to a directory does not. Several
# paths merge in order, later values win, and every file sees the values of the files before it (as systemd
# resolves `environment.d`). Returns a record of the variables, or a `key`/`value` table with `--no-transpose`;
# `--load` loads them with `load-env`, which converts PATH and every variable with an `ENV_CONVERSIONS` entry.
export def --env main [
  ...paths: path@_files # Files or directories to read, in order; `.env` when none is given
  --load (-l) # Load the variables into the process environment
  --no-transpose (-n) # Return the variables as a table instead of a record
]: nothing -> oneof<table<key: string, value: string>, record> {
  let targets: list<path> = if ($paths | is-empty) { ['.env'] } else { $paths }
  let files: list<path> = $targets | each --flatten {|p|
    if not ($p | path exists) { error raise $"not found: '($p)'" --kind not_found }
    # `path expand` resolves a symlink: a link to a directory is read as one, a link to a file as a file and a
    # dangling link (or a link to a directory) inside a directory is left out.
    if ($p | path expand | path type) == dir {
      glob --no-dir ($p | path join '*')
      | where ($it | path expand | path type) == file
      | sort
      | where (reader-of $it) != null
    } else { [$p] }
  }
  # A fold over a handful of files: each one is read with the previous results in scope (tiny accumulator). A
  # variable a bash file unsets (null) is dropped, one it empties ('') is kept.
  let vars: record = $files | reduce --fold {} {|file acc|
    $acc | merge (with-env $acc { read-file $file }) | record where value != null
  }
  if $load { load-env $vars }
  if $no_transpose { $vars | transpose key value } else { $vars }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _files []: nothing -> list<path> { '.env' | commandline complete --type=path }
