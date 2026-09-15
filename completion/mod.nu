use ../dispatch type
alias "dispatch type" = type

# ——— constants ————————————————————————————————————————————————————————————————

const F = {
  number: $.display
  filesize: KiB
  datetime: %+
  duration: min
}

const O = {
  sort: true
  case_sensitive: false
  completion_algorithm: prefix
  match_description: false
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def each-completion [c: closure]: [
  nothing -> oneof<list<any>, table<value: any>>
  list<any> -> list<any>
  table<value: any> -> table<value: any>
] { dispatch type --pipe {list: { par-each --keep-order $c } table: { update value $c }} }

# ——— definitions ——————————————————————————————————————————————————————————————

# Wrap an iterable containing custom completions into a record with completion options.
# - `$in` will have elements converted to strings with `to text` then compacted (with `--empty`)
# - `$options` will be run through `compact` to use their defaults when set to `null`
# - `--quote=auto` will serialize completion elements using `to nuon --serialize --raw-strings`
# - `--quote=single`|`--quote=double` will wrap completion elements coerced using `to nuon --no-commas`
@category core
@example 'transform a list into a completions record' {
  [1 2 3] | into completions
} --result={
  options: {
    sort: true
    case_sensitive: false
    completion_algorithm: prefix
    match_description: false
  }
  completions: ['1' '2' '3']
}
@example 'complete filenames and match full path descriptions' {
  glob ~/.config/**/config.nu --no-dir --depth=3
  | wrap description
  | insert value {|row| $row.description | path basename }
  | into completions {match_description: true}
} --result={
  options: {match_description: true}
  completions: [[description value]; [$nu.config-path "config.nu"]]
}
export def "into completions" [
  # nu-lint-ignore: add_doc_comment_exported_fn
  options: record = {}
  # Options for the custom completions (set any option to `null` to use default)
  --to-string (-q): closure
  # Custom swrializer for string formatting purposes
  --repr (-r): record = {}
  # record<number: cell-path, filesize: string, datetime: string, duration: string>
]: [
  list<any> -> record<options: record, completions: list<any>>
  table<value: any, description: string> -> record<options: record, completions: table>
] {
  let completions: list = compact --empty
  let repr: record = $F | merge $repr
  let format: closure = $to_string | default {
      dispatch type --pipe {
        string: {|| to nuon --serialize --no-commas }
        filesize: {|| format filesize $repr.filesize }
        duration: {|| format duration $repr.duration }
        datetime: {|| format date $repr.datetime }
        'number | int | float': {|| format number | get $repr.numbet }
        _: {|| let x | try { into string } catch { $x | to text } }
      }
    }
  return {
    options: ($O | merge $options | compact)
    completions: ($completions | each-completion $format)
  }
}
