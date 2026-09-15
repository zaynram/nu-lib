# Custom completion records: wrap a list, or a `value`/`description` table, with completion options.

use ../dispatch

# ——— constants ————————————————————————————————————————————————————————————————

# Default representation per value type (`--repr` overrides).
const REPR: record = {
  number: $.display
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
  # Representation overrides: `number` (a `format number` cell-path), `filesize`, `datetime` and `duration` (format strings)
]: [
  list<any> -> record<options: record, completions: list<string>>
  table<value: any, description: string> -> record<options: record, completions: table>
] {
  let completions: list = compact --empty
  let repr: record = $REPR | merge $repr
  # `default` would evaluate a closure argument as a lazy value instead of returning it.
  let format: closure = if $to_string != null { $to_string } else { # nu-lint-ignore: if_null_to_default
    # `match`, not `dispatch type`: this runs once per element and completion lists reach thousands of entries.
    {||
      let value: any = $in
      match ($value | describe | str replace --regex '<.*' '') {
        # Quote only what misparses as a bare argument: whitespace, quotes, `( ) [ { } | ; $`, a leading dash, keywords.
        string => { if $value =~ '[\s"\x27`()\[{}|;$]|^-.|^(true|false|null)$' { $value | to nuon } else { $value } }
        filesize => { $value | format filesize $repr.filesize }
        duration => { $value | format duration $repr.duration }
        datetime => { $value | format date $repr.datetime }
        int | float => { $value | format number | get $repr.number }
        _ => { $value | to text }
      }
    }
  }
  {
    options: ($OPTIONS | merge $options | compact)
    completions: ($completions | dispatch type --pipe {table: {|| update value $format } _: {|| each $format }})
  }
}
