# General helpers and utility methods.

# ——— submodules ———————————————————————————————————————————————————————————————

export use workspace

# ——— definitions —————————————————————————————————————————————————————————————

# Check for the existence of a value at a cell-path.
@example 'a present key' { {a: {b: 1}} | contains $.a.b } --result true
@example 'a missing index' { [1 2] | contains $.5 } --result false
export def contains [
  cell: cell-path
  # The cell-path to check for a value at (a present `null` counts as a value):
  # - Adding `?` suffix will make this always return `true`
  # - Adding a `!` suffix will make the check case-insensitive
]: oneof<list, record, table> -> bool { try { get $cell; return true } catch { return false } }

# Serialize a datetime in RFC 3339 format (default: now).
#
# A string is parsed with `into datetime` (keeping its time and offset; a bare date is midnight in the local time
# zone), and with `date from-human` (`in 2 hours`, `next monday`) when that fails.
@category date
@example 'a datetime' { (2020-01-02T03:04:05Z) | timestamp } --result '2020-01-02T03:04:05+00:00'
@example 'an ISO string' { '2020-01-02T03:04:05+02:00' | timestamp } --result '2020-01-02T03:04:05+02:00'
export def timestamp []: oneof<nothing, string, datetime> -> string {
  let input: any;
  match ($input | describe) {
    nothing => (date now)
    string => (try { $input | into datetime } catch { $input | date from-human })
    _ => $input
  } | format date %+
}
