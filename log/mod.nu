use std/log

export const FMT: string = $'(ansi wd)%DATE%(ansi rst)|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%'

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
