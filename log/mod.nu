# Logging aliases over std/log with a compact line format, `DATE|LEVEL|MSG` on stderr, coloured only when
# `config use-colors` says so.
#
# Import the module prefixed, `use log`, and call `log info …`: `use log *` puts a bare `debug` (and `error`) into
# scope, shadowing the builtin `debug` command (`5 | debug` then fails). Like `std/log`, levels below
# `$env.NU_LOG_LEVEL` (default: info) are not printed.
#
# This module and `std/log` are both named `log`, so use one or the other in a scope: after `use std/log`, a later
# `use log` re-imports std's module instead of this one, and a later `use std/log` shadows these aliases.
#
# `std/log` colours its lines itself (the level colour at `%ANSI_START%`, `ansi reset` at `%ANSI_STOP%`) and only
# checks for an explicit `use_ansi_coloring = false`, never the terminal or `NO_COLOR`; it even resets with that.
# The aliases therefore pass a format computed per call (`format`): the placeholders are left out when colours
# are off, which is the only way to keep std's output plain.

use std/log
use style

# The line format, as `std/log` placeholders: date, level and message separated by bars. `format` adds the styles.
export const FMT: string = '%DATE%|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%'

# The line format for the current colour setting (`style colors`).
#
# With colours on, `FMT` with the date dimmed; `--level` colours the level with that `ansi` name instead of the
# colour `std/log` gives the level. With colours off, `FMT` without the colour placeholders.
export def format [
  --level (-l): string # An `ansi` name for the level (default: `std/log`'s colour for it)
]: nothing -> string {
  if not (style colors) { return ($FMT | str replace --all --regex '%ANSI_(START|STOP)%' '') }
  $FMT
  | str replace '%DATE%' ('%DATE%' | style paint wd)
  | if $level == null { } else { str replace '%ANSI_START%%LEVEL%%ANSI_STOP%' ('%LEVEL%' | style paint $level) }
}

# Also the format of every `std/log` call in the importing scope, as decided when the module is imported.
export-env { $env.NU_LOG_FORMAT = (format) }

# Log a critical message using the library format.
export alias critical = log critical --format=(format)
# Log a debug message using the library format.
export alias debug = log debug --format=(format)
# Log an error message using the library format.
export alias error = log error --format=(format)
# Log an info message using the library format (level rendered in bold blue).
export alias info = log info --format=(format --level bb)
# Log a warning message using the library format.
export alias warning = log warning --format=(format)
