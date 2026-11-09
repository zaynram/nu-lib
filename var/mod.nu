# Wrapper for the universal variables from the `std-rfc/kv` module, with custom completions.

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv *
use error

const TABLE: string = 'var_kv_store'

# ——— aliases ——————————————————————————————————————————————————————————————————

# List the variables in the universal `kv` store as a table, with indices.
export def idx [
  --table (-t): string = $TABLE
  # Name of a specific table to list variables from
]: nothing -> table<key, value> {
  kv list --universal --table=$table | enumerate | flatten item
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Remove a variable from the universal `kv` store and return its value.
#
# Without a key, the last listed pair is removed.
# * If the table contains no pairs in this case, an error is raised.
#
# A key that is not stored returns null without an error, like a stored null value.
export def pop [
  key?: string@_variable_names
  # Name of the variable to remove (if omitted, the `| last` pair will be dropped)
  --table (-t): string = $TABLE
  # Name of a specific table to remove the variable from
]: nothing -> oneof<nothing, any> {
  $key
  | default (kv list --universal --table=$table | last 1).0?.key
  | default {||
    error raise 'there are no stored key-value pairs' --kind not_found
  } | kv drop --universal --table=$table $in
}

# Assign one or more pairs to the universal `kv` store, in order.
# Prioritization is given to input's pairs, then `key`/`value`.
#
# Returns the whole store as a record, or nothing with `--silent`.
# Having no pairs to set is an error, unless `--silent` is given.
# * `var set <key>` without a value stores null.
export def set [
  key?: string@_variable_names
  # The name to store the variable under (or overwrite)
  value: any = null
  # The value to assign under the provided key
  --silent (-s)
  # Disable returning the full variable set as a record
  --table (-t): string = $TABLE
  # Name of a specific table to store the pair(s) in
]: oneof<nothing, record, table<key: string, value: any>> -> oneof<nothing, record> {
  let pairs: table = match ($key | describe) {
    nothing => ()
    string => (append {key: $key value: $value})
  } | match ($in | describe | str replace --regex <.+ '') {
      record => (transpose key value)
      table => ()
      # an empty table describes as `list<any>`
      nothing | list => {
        if $silent { return }
        let msg: string = 'no key-value pairs were provided'
        error raise $msg --kind=invalid_argument
      }
    }
  for row in $pairs {
    kv set --universal --table=$table $row.key $row.value
  }
  if not $silent {
    kv list --universal --table=$table
    | transpose --ignore-titles --header-row --as-record
  }
}

# Interact with variables in the universal `kv` store.
# - Pipeline input will be treated the same as the `$value` argument, if present.
# - If both `$value` and pipeline input are present, the pipeline input will be ignored.
@category core
export def main [
  key?: string@_variable_names
  # Name of a variable to get or set (if omitted, variables are returned as record)
  value?: any
  # Set variable to this value (ignored if `null`; use `--drop`/`var pop` instead)
  --drop (-d)
  # Clear the variable under `$key` (prioritized over other flags)
  --table (-t): string = $TABLE
  # Name of a specific table to use for interactions
]: oneof<nothing, any> -> oneof<nothing, record, any> {
  if $key == null {
    kv list --universal --table=$table
    | transpose --ignore-titles --header-row --as-record
    | default --empty {}
  } else if $drop {
    kv drop --universal --table=$TABLE $key
  } else {
    let input: any;
    match ($value | default $input) {
      null => (kv get --universal --table=$table $key)
      $x => (kv set --universal --table=$table $key $x)
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _variable_names [buffer: string]: nothing -> table {
  let table: string = $buffer
    | parse --regex '\s*(--table|-t)[\=|\s]{1}(?<table>\w+)\s*'
    | get $.0?.table
    | default --empty $TABLE
    | str trim
  kv list --universal --table=$table
  | if $in == [] { } else {
    rename --column={key: value value: description}
    | update description { describe }
  }
}
