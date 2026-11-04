# Wrapper for the universal variables from the `std-rfc/kv` module, with custom completions.

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv *

# ——— aliases ——————————————————————————————————————————————————————————————————

# List the variables in the universal `kv` store as a table.
export alias ls = kv list --universal

# ——— definitions ——————————————————————————————————————————————————————————————

# Remove a variable from the universal `kv` store.
export def pop [
  key?: string@_variable_names
  # The name of the variable to remove (if omitted, the `| last` pair will be dropped)
]: nothing -> oneof<nothing, any> {
  match ($key | default { kv list --universal | last | get $.key? }) {
    null => { error make --unspanned 'there are no stored key-value pairs' }
    $k => { kv drop --universal $k }
  }
}

# Assign one or more pairs to the universal `kv` store.
export def set [
  key?: string@_variable_names
  # The name to store the variable under (or overwrite)
  value: any = null
  # The value to assign under the provided key
  --silent (-s)
  # Disable returning the full variable set as a record
]: oneof<nothing, record, table<key: string, value: any>> -> oneof<nothing, record> {
  match ($in | describe | split words | first) {
    nothing => []
    table => { }
    record => { transpose key value }
  } | if $key != null { append {key: $key value: $value} } else { }
  | if $in != [] {
    par-each --keep-order {|row| get value | kv set --universal $row.key }
    if not $silent { kv list --universal | transpose --ignore-titles --header-row --as-record }
  } else {
    if not $silent { error make --unspanned 'no key-value pairs were provided' }
  }
}

# Interact with variables in the universal `kv` store.
# - Pipeline input will be treated the same as the `$value` argument, if present.
# - If both `$value` and pipeline input are present, the pipeline input will be ignored.
@category core
export def main [
  key?: string@_variable_names
  # The name of a variable to get or set (if omitted, the stored variables will be returned as a record)
  value?: any
  # Set the variable to this value (ignored if `null`; use `--drop` or `var pop` to remove pairs)
  --drop (-d)
  # Clear the variable under `$key` (prioritized over other flags)
]: oneof<nothing, any> -> oneof<nothing, record, any> {
  let input: any;
  if $key == null { kv list --universal | transpose --ignore-titles --header-row --as-record | default --empty {} | return $in }
  if $drop { kv drop --universal $key | return $in }
  $value | default $input | match ($in | describe) {
    nothing => { ignore | kv get --universal $key }
    _ => { kv set --universal $key }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _variable_names []: nothing -> table {
  kv list --universal | if $in == [] { } else {
    rename --column={key: value value: description}
    | update description { describe }
  }
}
