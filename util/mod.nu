# General helpers and utility methods.

# nu-lint-ignore-file: unchecked_get_index, require_main_with_stdin, add_doc_comment_exported_fn

# ——— imports —————————————————————————————————————————————————————————————————

use ($nu.data-dir | path basename --replace nupm/modules/session) edit

export use std/help
export use std/util [ "path add" null-device ellie ]

const EXE: path = $nu.current-exe | path expand --strict --no-symlink

# ——— helpers ——————————————————————————————————————————————————————————————————

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

# Ensure a joined path contains no backslashes on Windows; same as `path join` on other platforms.
@category path
export def fix-path [...segments: string]: path -> path {
  path join ...$segments | match $nu.os-info.name {
    windows => { str replace --all '\' '/' }
    _ => { }
  }
}


# Serialize a datetime (default: now; strings are parsed as human dates) in RFC 3339 format.
@category date
export def timestamp []: oneof<nothing, string, datetime> -> string {
  match ($in | describe) { nothing => { date now } string => { date from-human } _ => { } } | format date %+
}

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
    let rest: list = append $rest | compact --empty | default --empty [$cwd] | path expand
    if $env has ZELLIJ {
      edit --workspace=$cwd $rest.0? ...($rest | skip 1)
    } else if $nu.os-info.name != windows and (on-path editor) {
      cd $cwd
      run-external editor ...$rest
    } else {
      cd $cwd
      run-external $env.config.buffer_editor ...$rest
    }
  } else {
    if $env has ZELLIJ {
      help editor
    } else if $nu.os-info.name != windows and (on-path man editor) {
      man editor
    } else {
      help $env.config.buffer_editor
    }
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
    run-internal $mode { which $in --all | where type == external | is-not-empty }
  }
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
