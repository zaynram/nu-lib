# Custom completion records: wrap a list, or a `value`/`description` table, with completion options.

# ——— constants ————————————————————————————————————————————————————————————————

# Default representation per value type (`--repr` overrides).
const REPR: record = {
  number: $.display!
  filesize: KiB
  datetime: %+
  duration: min
}

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
        | match ($in | describe | str replace --regex '<.*' '') {
          # `$in` in `match` guards errors at parse time, so we need bound variable here
          string if $x =~ '[\s"\x27`()\[{}|;$]|^-.|^(true|false|null)$' => { to nuon }
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
    completions: ($value | if $table { update value $format } else { par-each --keep-order $format })
  }
}
