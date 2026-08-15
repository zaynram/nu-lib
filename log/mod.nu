use std/log

export const FMT: string = $'(ansi wd)%DATE%(ansi rst)|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%'

export alias info = log info --format=($FMT | str replace %ANSI_START% (ansi bb))
export alias critical = log critical --format=$FMT
export alias debug = log debug --format=$FMT
export alias error = log error --format=$FMT
export alias info = log info --format=$FMT
export alias warning = log warning --format=$FMT
