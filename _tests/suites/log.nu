# `log` aliases: `test _tests/suites/log.nu`.
#
# Log lines go to stderr, so every test runs the module in a sandboxed child and reads its stderr. A child has no
# terminal, so lines are plain unless the code sets `use_ansi_coloring = true` first.
use log
use ../mod.nu *

# Run `code` after `use log` in a child; return its complete record (stderr as lines, ANSI kept).
def logged [code: string --vars: record = {} --prelude: string = 'use log']: nothing -> record {
  with-sandbox {|ctx| sandboxed $ctx $code --prelude $prelude --vars $vars | update stderr { lines } }
}

const LINE = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?\|(?<level>[A-Z]{3})\|(?<msg>.*)$'
const COLORED = '$env.config.use_ansi_coloring = true'

def "test import sets the std log format" []: nothing -> nothing {
  assert equal (logged 'print ($env.NU_LOG_FORMAT == (log format))').stdout "true\n" 'export-env sets NU_LOG_FORMAT to the format for the setting at import'
  assert equal (logged 'print $env.NU_LOG_FORMAT').stdout "%DATE%|%LEVEL%|%MSG%\n" 'plain without a terminal'
  let styled = logged 'print $env.NU_LOG_FORMAT' --prelude $"($COLORED); use log"
  assert equal $styled.stdout $"($log.FMT | str replace '%DATE%' $'(ansi wd)%DATE%(ansi reset)')\n" 'with colours on at import, the date is dimmed'
}

def "test format constant" []: nothing -> nothing {
  assert equal $log.FMT '%DATE%|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%' 'date, level and message separated by bars, no styles'
}

def "test format follows the colour setting" []: nothing -> nothing {
  $env.config.use_ansi_coloring = false
  assert equal (log format) '%DATE%|%LEVEL%|%MSG%' 'off: the colour placeholders are left out'
  assert equal (log format --level bb) '%DATE%|%LEVEL%|%MSG%' 'off: a level colour changes nothing'
  $env.config.use_ansi_coloring = true
  assert equal (log format) $'(ansi wd)%DATE%(ansi reset)|%ANSI_START%%LEVEL%%ANSI_STOP%|%MSG%' 'on: the date is dimmed, std colours the level'
  assert equal (log format --level bb) $'(ansi wd)%DATE%(ansi reset)|(ansi bb)%LEVEL%(ansi reset)|%MSG%' 'on: the level takes the given colour'
}

def "test every level writes one line to stderr" []: nothing -> nothing {
  let res = logged 'log critical one; log error two; log warning three; log info four'
  assert equal $res.stdout '' 'nothing on stdout'
  let rows = $res.stderr | ansi strip | parse --regex $LINE
  assert equal ($rows | select level msg) [[level msg]; [CRT one] [ERR two] [WRN three] [INF four]] 'level codes and messages'
}

def "test lines are plain when colours are off" []: nothing -> nothing {
  let res = logged 'log critical one; log error two; log warning three; log info four'
  assert ($res.stderr | all { $in !~ '\e\[' }) $'no escape sequences without a terminal: ($res.stderr)'
  assert equal ($res.stderr | parse --regex $LINE | get msg) [one two three four] 'the lines parse as written'
}

def "test lines are coloured when colours are on" []: nothing -> nothing {
  let res = logged $"($COLORED); log warning w; log info i"
  assert ($res.stderr | all { $in =~ '\e\[' }) $'escape sequences with colours on: ($res.stderr)'
  assert str contains $res.stderr.0? $'|(ansi yellow)WRN(ansi reset)|' 'a warning takes the std colour for the level'
  assert equal ($res.stderr | ansi strip | parse --regex $LINE | get msg) [w i] 'the same text underneath'
}

def "test info renders its level in bold blue" []: nothing -> nothing {
  let line = (logged $"($COLORED); log info hi").stderr.0?
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
