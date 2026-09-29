# Type transformation and coercion methods.

# ——— definitions ——————————————————————————————————————————————————————————————

# Join one or more segments to an existing cell-path.
export def "cell-path join" [
  --optional (-o)
  # Make any bare segments optional by default
  --insensitive (-i)
  # Make any bare segments insensitive by default
  ...segments: oneof<int, string, record<optional: bool, insensitive: bool, value: oneof<int, string>>>
  # Segments to join with the pipeline input
]: cell-path -> cell-path {
  let default: record = {optional: $optional insensitive: $insensitive value: null}; [
    ...($in | split cell-path)
    ...($segments | par-each --keep-order {|it| match ($it | describe) { string | int => ($default | default $it value) _ => $it } })
  ] | into cell-path
}
