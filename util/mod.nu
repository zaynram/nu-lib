# General helpers and utility methods.

# ——— imports —————————————————————————————————————————————————————————————————

use std/util [ "path add" null-device ]
use std/iter flat-map

use completion "into completions"
use command post-complete

# ——— definitions —————————————————————————————————————————————————————————————

# Check for the existence of a value at a cell-path.
export def contains [
  cell: cell-path
  # The cell-path to check for a value at:
  # - Adding `?` suffix will make this always return `true`
  # - Adding a `!` suffix will make the check case-insensitive
]: oneof<list, record, table> -> bool { try { get $cell; return true } catch { return false } }

# Serialize a datetime (default: now; strings are parsed as human dates) in RFC 3339 format.
@category date
export def timestamp []: oneof<nothing, string, datetime> -> string {
  match ($in | describe) { nothing => (date now) string => (date from-human) _ => () } | format date %+
}
