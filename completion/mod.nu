# Custom completion records: wrap a list, or a `value`/`description` table, with completion options.

export use std/util structure

# ——— constants ————————————————————————————————————————————————————————————————

# Default representation per value type (`--repr` overrides).
const REPR: record = {
  number: $.display!
  filesize: KiB
  datetime: %+
  duration: min
}

# A bare string that would misparse as an argument: quoted with `to nuon`.
const UNSAFE: string = '[\s"\x27`()\[{}|;$]|^-.|^(true|false|null)$'
# The same test over a whole element, for the vectorised pass.
const UNSAFE_ELEMENT: string = $"\(?s\)^\(.*?\(?:($UNSAFE)\).*\)$"

# Default completion options (`options` overrides; `null` restores the Nushell default).
const OPTIONS: record = {
  sort: true
  case_sensitive: false
  completion_algorithm: prefix
  match_description: false
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Wrap an iterable of custom completions into a record with completion options.
# - elements are formatted to strings by type after `compact --empty`; strings are nuon-quoted only when a bare argument would misparse
# - `$options` merge over the defaults; set an option to `null` to fall back to the Nushell default
@category core
@example 'transform a list into a completions record' {
  [1 2 3] | into completions
} --result={
  options: {sort: true case_sensitive: false completion_algorithm: prefix match_description: false}
  completions: ['1' '2' '3']
}
@example 'complete file names and match against their descriptions' {
  [[description value]; ['/tmp/a b.nu' 'a b.nu']] | into completions {match_description: true}
} --result={
  options: {sort: true case_sensitive: false completion_algorithm: prefix match_description: true}
  completions: [[description value]; ['/tmp/a b.nu' '"a b.nu"']]
}
export def "into completions" [
  # nu-lint-ignore: add_doc_comment_exported_fn
  options: record = {}
  # Completion options merged over the defaults
  --to-string (-t): closure
  # Custom element formatter, replacing the per-type default
  --repr (-r): record = {}
  # Representation overrides: `number` (a `format number` cell-path), `filesize`, `date` and `duration` (format strings)
]: [
  list<any> -> record<options: record, completions: list<string>>
  table<value: any, description: string> -> record<options: record, completions: table<value: string, description: string>>
] {
  let value = compact --empty
  let merged: record = $REPR | merge $repr
  let table: bool = ($in | describe) starts-with table
  let format: closure = $to_string | default {
      # `match` built-in is ~20x faster than `dispatch type` so it wins here
      return {||
        let x: any; $x
        # `$in` evaluate properly in the `match` argument subexpression
        # no arm below is generic, so `list<int>` and friends reach `_` without normalising
        | match ($in | describe) {
          # `$in` in `match` guards errors at parse time, so we need bound variable here
          string if $x =~ $UNSAFE => { to nuon }
          string => { }
          filesize => { format filesize $merged.filesize }
          datetime => { format date $merged.datetime }
          duration => { format duration $merged.duration }
          number | int | float => { format number | get $merged.number }
          _ => { to text }
        }
      }
    }
  return {
    options: ($OPTIONS | merge $options | compact)
    # `--keep-order`: completers that pass `sort: false` (time, hook) rely on the input order surviving.
    completions: (
      $value | if $table {
        update value $format
      } else if $to_string == null and ($value | describe) == 'list<string>' {
        quote-strings $format
      } else { par-each --keep-order $format }
    )
  }
}

# The string arms of the default formatter over a whole list at once: one regex pass quotes what `to nuon` would.
# It is exact unless a quoted element holds a character `to nuon` escapes, when the formatter runs instead.
# A regex costs about 7 us per element in a row condition and 0.2 us in `str replace`: 1.4k names, 6.1 ms to 0.9 ms.
def quote-strings [format: closure]: list<string> -> list<string> {
  let value: list<string>;
  let quoted: list<string> = $value | parse --regex $UNSAFE_ELEMENT | get capture0
  if ($quoted | str join '') =~ '["\\\x00-\x1f\x7f]' {
    $value | par-each --keep-order $format
  } else { $value | str replace --regex $UNSAFE_ELEMENT '"$1"' }
}

# Convert a commandline buffer into a list of token spans.
export def "into spans" [
  --long (-l)
  # Return the full `structure` table instead of only the token texts
  --unalias (-u)
  # Replace the first span with its alias expansion's first word, if found
  --raw (-r)
  # Disable insertion of empty quotes for trailing whitespace
]: string -> list<string> {
  let buffer: string;
  structure $in | if $unalias {
    update $.0.text {|name: string|
      scope aliases
      | where name == $name
      | get $.0?.expansion
      | match $in { null => $name _ => { split words | first } }
    }
  } else { }
  | if not $raw and $buffer =~ '\s+$' {
    let pos: int = $buffer | str length --chars | $in - 1
    $in | append {text: '' kind: none span: {start: $pos end: $pos}}
  } else { }
  | if $long { } else { get $.text }
}
