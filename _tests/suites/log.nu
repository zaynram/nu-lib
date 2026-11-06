# `log` aliases: `test _tests/suites/log.nu`.
#
# Log lines go to stderr, so every test runs the module in a sandboxed child and reads its stderr.
use log
use ../mod.nu *

# Run `code` after `use log` in a child; return its complete record (stderr as lines, ANSI kept).
def logged [code: string --vars: record = {}]: nothing -> record {
  with-sandbox {|ctx| sandboxed $ctx $code --prelude 'use log' --vars $vars | update stderr { lines } }
}

const LINE = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?\|(?<level>[A-Z]{3})\|(?<msg>.*)$'

def "test import sets the std log format" []: nothing -> nothing {
  assert equal (logged 'print ($env.NU_LOG_FORMAT == $log.FMT)').stdout "true\n" 'export-env sets NU_LOG_FORMAT'
}

def "test format constant" []: nothing -> nothing {
  assert equal ($log.FMT | ansi strip) '%DATE%|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%' 'date, level and message separated by bars'
}

def "test every level writes one line to stderr" []: nothing -> nothing {
  let res = logged 'log critical one; log error two; log warning three; log info four'
  assert equal $res.stdout '' 'nothing on stdout'
  let rows = $res.stderr | ansi strip | parse --regex $LINE
  assert equal ($rows | select level msg) [[level msg]; [CRT one] [ERR two] [WRN three] [INF four]] 'level codes and messages'
}

def "test info renders its level in bold blue" []: nothing -> nothing {
  let line = (logged 'log info hi').stderr.0?
  assert str contains $line $'|(ansi bb)INF' 'bold blue level'
  assert ($line starts-with (ansi wd)) 'the date is dimmed'
}

def "test debug is hidden at the default level" []: nothing -> nothing {
  assert equal (logged 'log debug hidden').stderr [] 'below the default info level'
}

def "test debug is shown at the debug level" []: nothing -> nothing {
  let rows = (logged 'log debug shown' --vars {NU_LOG_LEVEL: debug}).stderr | ansi strip | parse --regex $LINE
  assert equal ($rows | select level msg) [[level msg]; [DBG shown]] 'NU_LOG_LEVEL=debug'
}

def "test levels below the configured one are hidden" []: nothing -> nothing {
  let rows = (logged 'log info a; log warning b; log error c' --vars {NU_LOG_LEVEL: error}).stderr | ansi strip | parse --regex $LINE
  assert equal ($rows | get level) [ERR] 'only error and above'
}

def "test prefixed import keeps the builtin debug" []: nothing -> nothing {
  assert equal (logged '5 | debug | print').stdout "5\n" '`use log` does not shadow `debug`'
}

def "test glob import exposes bare aliases" []: nothing -> nothing {
  let res = with-sandbox {|ctx| sandboxed $ctx 'info bare' --prelude 'use log *' }
  assert equal ($res.stderr | ansi strip | lines | parse --regex $LINE | get msg) [bare] '`use log *` gives `info`'
}
