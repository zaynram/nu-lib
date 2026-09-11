# ——— imports —————————————————————————————————————————————————————————————————

use ../path resolve
use ($nu.data-dir | path basename --replace nupm/modules/session) edit

export use std/util [ "path add" null-device ellie ]
export module std/help
export module std/bench

const EXE: path = $nu.current-exe | path expand --strict --no-symlink

# ——— helpers ——————————————————————————————————————————————————————————————————

alias quote-char = match $in {
  single => [`'` `'`]
  double => [`"` `"`]
  auto => ['`' '`']
}

def each-completion [c: closure]: [
  nothing -> oneof<list<any>, table<value: any>>
  list<any> -> list<any>
  table<value: any> -> table<value: any>
] {
  match ($in | describe | split words | first) {
    list => { par-each --keep-order $c }
    table => { update value $c }
  }
}

# ——— definitions —————————————————————————————————————————————————————————————

# Compute the difference between two datetimes as a duration, or evaluate the datetime after a duration as a datetime.
export def "date diff" [
  d: oneof<datetime, duration> = 0us
  # Offset or comparison date to compute the duration from the input date (or now)
  --tz: string@_timezones = local
  # Timezone to convert datetimes to before operating
  --format (-f): string@_datetime_formats
  # Return a string representation of the datetime in this format
  --invert (-i)
  # Reverse the mathemetical operation on the argument; will flip the anchor if datetime, otherwise will invert the sign of a duration
  --record (-r)
  # Return the datetime or duration difference as a record
]: oneof<nothing, string, datetime> -> oneof<duration, datetime, string> {
  match ($in | describe) { datetime => { } nothing => { date now } string => { date from-human } }
  | date to-timezone $tz
  | match ($d | describe) { datetime if $invert => { $d - $in } duration if not $invert => { $in + $d } _ => { $in - $d } }
  | if $format != null and ($in | describe) == datetime { format date $format } else if $record { into record } else { }
}

# Return a serialization of a datetime, optionally for a computed time delta.
export alias timestamp = date diff --format=%+

# Wrap an iterable containing custom completions into a record with completion options.
# - `$in` will have elements converted to strings with `to text` then compacted (with `--empty`)
# - `$options` will be run through `compact` to use their defaults when set to `null`
# - `--quote=auto` will serialize completion elements using `to nuon --serialize --raw-strings`
# - `--quote=single`|`--quote=double` will wrap completion elements coerced using `to nuon --no-commas`
@category core
@example 'transform a list into a completions record' { [1 2 3] | into completions }
@example 'complete filenames and match full path descriptions' {
  glob * --no-dir --depth=3
  | wrap description
  | insert value {|row| $row.description | path basename }
  | into completions {match_description: true}
}
export def "into completions" [
  options: record = {
    sort: true
    case_sensitive: false
    completion_algorithm: prefix
    match_description: false
  }
  # Options for the custom completions (set any option to `null` to use default)
  --quote (-q): string@[single double auto none] = auto
  # Mode for wrapping completion items in quotes for ergonomics on the commandline
]: [
  list<any> -> record<options: record, completions: list<any>>
  table<value: any, description: string> -> record<options: record, completions: table<value: any, description: string>>
] {
  {
    options: ($options | compact)
    completions: (
      $in | compact --empty | match $quote {
        auto => { each-completion { if $in =~ \s+ { to nuon --serialize --raw-strings } else { to text } } }
        single => { each-completion { $"'($in | to nuon --no-commas)'" } }
        double => { each-completion { $'"($in | to nuon --no-commas)"' } }
        _ => { }
      }
    )
  }
}

# Open a file in the default editor or the editor pane of an active Zellij session.
@category core
export def --wrapped editor [
  --cwd (-d): directory = . # Set the working directory for the editor session
  ...rest: string # Pass arguments to the wrapped editor
]: oneof<nothing, path, list<path>> -> nothing {
  if $rest not-has `--help` {
    let rest: list = append $rest | compact --empty | default --empty $cwd | resolve
    if $env has ZELLIJ {
      edit --workspace=$cwd $rest.0? ...($rest | skip 1)
    } else {
      cd $cwd; run-external editor ...$rest
    }
  } else {
    if $env has ZELLIJ { help editor } else { man editor }
  }
}

# Check if command(s) are available on PATH.
#
# Note that `all` is used for the test by default so if more than one
# name is provided then any missing command will return false. Pass
# `--mode=any` for the alternate behavior.
@category filesystem
export def on-path [
  ...names: string@_executables # Command name (if the name is completed, it's on PATH already)
  --mode (-m): string@[all any] = all
]: oneof<nothing, string, list<string>> -> bool {
  append $names | compact --empty | if ($in | is-empty) {
    error make --unspanned 'no commands were provided'
  } else {
    run-internal $mode { which $in | is-not-empty }
  }
}

alias resolve-cmd = try { which $in | get $.0?.path }

# Return the absolute path of a command if found, otherwise null.
@category core
export def command [
  ...names: string
  # The names of the commands to resolve the paths of
  --prune (-p)
  # Prune entries for commands that could not be resolved (warning: may desync input/output list indices)
  --as-record (-r)
  # Return a mapping of command names to their locations
]: [
  nothing -> oneof<nothing, path, list<path>, record>
  string -> oneof<path, list<path>, record>
  list<string> -> oneof<list<path>, record>
] {
  append $names
  | match ($in | length) { 0 => { return } 1 => { first } _ => { } }
  | if $as_record { each {|it| resolve-cmd | wrap $it } | into record } else { each { resolve-cmd } }
  | match ($in | describe) { string | nothing => { } _ if $prune => { compact | sort } _ => { sort } }
}

# Run closures based on the current execution platform.
#
@category platform
export def --wrapped match-os [
  record: oneof<record, record<linux: any, macos: any, windows: any, bsd: any>> = {}
  # Mapping of OS names to values or closures
  --default (-d): any = null
  # Use this if no item was provided for the current platform
  --execute (-e) = true
  # If the resolved value is a closure, run it and return the result
  --capture (-c) = true
  # Capture any errors raised when executing a closure (only effective with `--execute`)
  ...args: string
  # Arguments to pass through to the closure
]: oneof<record, nothing> -> oneof<nothing, any> {
  default $record
  | get --optional $nu.os-info.name
  | default $default
  | match ($in | describe) {
    closure if $execute => { do --ignore-errors=(not $capture) $in ...$args }
    _ => { return $in }
  }
}

# Replace the current shell instance with a fresh one.
#
# Optionally, a record can be piped in which will be merged into
# the process environment.
@category shells
export def --env --wrapped reload [
  --erase (-e) # Erase the history (clear without keeping scrollback)
  ...rest: string # Additional arguments for the Nushell invocation
]: oneof<nothing, record> -> nothing {
  match-os {linux: {|| reset (if $erase { '-wc' } else { '-w' }) }}
  with-env ($in | default {}) {
    if $nu.is-interactive { hide-env --ignore-errors pid }
    if $nu.is-login { exec $EXE --login ...$rest } else { exec $EXE ...$rest }
  }
}

# Substitute a falsy value with a default or closure.
@category core
export def substitute [
  default?: oneof<nothing, any> # The value to substitute when the input is falsy
  --run (-x): closure # Execute a closure when the input is falsy(priority over default if given)
  --empty-ok (-e) # Treat empty containers as truthy and return them
]: oneof<nothing, any> -> oneof<nothing, bool, any> {
  let x: any = $in
  match ($x | describe | split words | first) {
    list | record | table => { if ($x | is-not-empty) or $empty_ok { return $x } }
    _ => { try { if ($x | into bool --relaxed) { return $x } } }
  }
  match $run { null => $default _ => { do --capture-errors $run } }
}

# Link a binary to the user bin directory.
@category platform
export def bin-link [
  name: oneof<string, path>@_executables # The name of the binary to link
]: nothing -> path {
  let config: record<link: path, regex: string> = match-os {
    linux: {
      link: $"/usr/bin/($name)"
      regex: $"^/\(bin|usr/bin)/($name)$"
    }
    windows: {
      let lnk: path = $env.USERPROFILE | path join .local bin $name
      return {link: $lnk regex: $lnk}
    }
  }
  match ($config.link | path type) {
    symlink if ($config.link | path exists) => { return $config.link }
    symlink => {
      sudo unlink $config.link out+err>| complete
      | if $in.exit_code? != 0 { error 'unable to remove link' bin-link dangling_symlink }
    }
  }
  which --all $name
  | where path !~ $config.regex
  | get --optional 0.path
  | if $in == null { error "unable to detect source binary" } else {
    let path: path = $in
    match-os {
      linux: { sudo ln -s $path $config.link out+err>| complete }
      windows: { mklink $config.link $path out+err>| complete }
    } | if $in.exit_code? != 0 {
      error 'unable to link binary' bin-link non_zero_exit_code
    } else {
      return $config.link
    }
  }
}

# Abstracted HTTP GET method with dynamic URL construction.
@category network
export def fetch [
  url?: string # The URL to form request with (protocol can be omitted)
  --pipe: oneof<string, list<string>> # Pipe the content to the executable, optionally with arguments
  --save: path # Save the content to this path
]: [
  oneof<nothing, record<host: string, path: string>> -> oneof<nothing, path, string>
] {
  let content: string = match $url {
    null => { $in | default { error make --unspanned 'no url was provided' } }
    $s if $s =~ `^http[s]*://\w+` => { $s | url parse }
    $s if $s =~ `^\w+\.\w+` => { $'https://($s)' | url parse }
  } | default https scheme
    | url join
    | http get --raw $in

  let args: list = [$pipe] | flatten | compact
  let has_pipe: bool = $args | is-not-empty
  let has_save: bool = $save != null

  if not ($has_pipe or $has_save) { return $content }
  if $has_pipe { $content | run-external ...$args | to text | print }
  if $has_save { $content | save --raw --force $save | return $save }
}

# ——— helpers —————————————————————————————————————————————————————————————————

def error [msg: string ...code: string]: oneof<nothing, record<stdout: string>> -> error {
  let details: record = match $in {
    {stdout: $s} | {stderr: $s} => $"[output]\n($s)"
    $s if ($s | describe) == string => $s
    null => ''
  } | wrap help
    | insert msg $msg
    | insert code {
      $code
      | default --empty [internal_error]
      | prepend [common util]
      | str join ::
    }
    | compact --empty
  error make --unspanned $details
}

# ——— completions —————————————————————————————————————————————————————————————

def _executables []: nothing -> oneof<record, list> {
  which | where type == external | get command | path parse | get stem | into completions
}

def _timezones []: nothing -> oneof<record, list> {
  'date to-timezone ' | commandline complete | into completions
}

def _datetime_formats []: nothing -> record {
  format date --list | reject Example | rename --column={Specification: value Description: description} | into completions
}
