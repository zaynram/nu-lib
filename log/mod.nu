# Logging aliases over std/log with a compact, colored line format: `DATE|LEVEL|MSG` on stderr.
#
# Import the module prefixed, `use log`, and call `log info …`: `use log *` puts a bare `debug` (and `error`) into
# scope, shadowing the builtin `debug` command (`5 | debug` then fails). Like `std/log`, levels below
# `$env.NU_LOG_LEVEL` (default: info) are not printed.
#
# This module and `std/log` are both named `log`, so use one or the other in a scope: after `use std/log`, a later
# `use log` re-imports std's module instead of this one, and a later `use std/log` shadows these aliases.

use std/log

export const FMT: string = $'(ansi wd)%DATE%(ansi rst)|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%'

# Also the format of every `std/log` call in the importing scope.
export-env { $env.NU_LOG_FORMAT = $FMT }

# Log a critical message using the library format.
export alias critical = log critical --format=$FMT
# Log a debug message using the library format.
export alias debug = log debug --format=$FMT
# Log an error message using the library format.
export alias error = log error --format=$FMT
# Log an info message using the library format (level rendered in bold blue).
export alias info = log info --format=($FMT | str replace %ANSI_START% (ansi bb))
# Log a warning message using the library format.
export alias warning = log warning --format=$FMT
