# ——— imports —————————————————————————————————————————————————————————————————

use ../vendor modules
use ../path resolve
use ($modules | path join session) edit

export use std "path add"

# ——— definitions —————————————————————————————————————————————————————————————

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

# Run closures based on the current execution platform.
#
@category platform
export def --wrapped match-os [
  record: oneof<nothing, record<linux: oneof<any, closure>>, record<macos: oneof<any, closure>>, record<windows: oneof<any, closure>>, record<bsd: oneof<any, closure>>, record<other: oneof<any, closure>>> = null # Mapping of OS names to values or closures (properties are optional)
  --linux (-l): oneof<any, closure> # Linux-only value or closure
  --macos (-m): oneof<any, closure> # MacOS-only value or closure
  --windows (-w): oneof<any, closure> # Windows only value or closure
  --bsd (-b): oneof<any, closure> # BSD-only value or closure
  --other (-o): oneof<any, closure> # Use this if no item was provided for the current platform
  ...args: string # Arguments to pass through to the closure
]: [
  oneof<nothing, record<linux: oneof<any, closure>, macos: oneof<any, closure>, windows: oneof<any, closure>, bsd: oneof<any, closure>, other: oneof<any, closure>>> -> oneof<nothing, any>
] {
  default { $record | default {} }
  | default { $linux } linux
  | default { $macos } macos
  | default { $windows } windows
  | default { $bsd } bsd
  | default { $other } other ...($in | columns)
  | get --optional $nu.os-info.name
  | if ($in | describe) == closure { do --capture-errors $in ...$args } else { }
}

# Replace the current shell instance with a fresh one.
#
# Optionally, a record can be piped in which will be merged into
# the process environment.
@category shells
export def --env reload [
  --erase (-e) # Erase the history (clear without keeping scrollback)
  --fresh (-f) # Clear the cached PID to allow rerunning startup actions
  --login (-l) = true # Run Nushell as a login shell
  --reset (-r) = true # Redraw the UI (run `reset`)
]: oneof<nothing, record> -> nothing {
  default {} | load-env
  if $reset { match-os --linux { reset } }
  if $fresh { $env.pid = null }
  if $erase { clear } else { clear --keep-scrollback }
  if $login { exec nu --login } else { exec nu }
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

def _executables []: nothing -> list {
  which | where type == external | get command | path parse | get stem
}
