# General helpers and utility methods.

# ——— imports —————————————————————————————————————————————————————————————————

use std/util [ "path add" null-device ]
use std/iter flat-map

use ../dispatch
use ../completion "into completions"
use ../error post-complete

# ——— constants ————————————————————————————————————————————————————————————————

const EXE: path = $nu.current-exe | path expand --strict --no-symlink

# ——— definitions —————————————————————————————————————————————————————————————

# Check for the existence of a value at a cell-path.
export def contains [
  cell: cell-path
  # The cell-path to check for a value at:
  # - Adding `?` suffix will make this always return `true`
  # - Adding a `!` suffix will make the check case-insensitive
]: oneof<list, record, table> -> bool { try { get $cell; return true } catch { return false } }

# Serialize a datetime (default: now; strings are parsed as human dates) in RFC 3339 format.
@category date
export def timestamp []: oneof<nothing, string, datetime> -> string {
  dispatch type --pipe {nothing: {|| date now } string: {|| date from-human } _: {|| }} | format date %+
}

# Run an external command and return its `complete` record.
export def --wrapped attempt [
  name: string
  # The name or path of the external command to run
  ...rest: string
  # Arguments to pass to the external command
  --check (-c)
  # Raise an error on non-zero `exit_code`; otherwise return `stdout`
  --merge (-m)
  # Merge `stdout` and `stderr` together into `stdout`
]: [
  oneof<nothing, string> -> oneof<string, record<stdout: string, stderr: string, exit_code: int>, error>
] {
  if $merge {
    run-external $name ...$rest out+err>|
  } else {
    run-external $name ...$rest
  } | complete
  | if $check { post-complete $name } else { }
}

# Open a file in the default editor or the editor pane of an active Zellij session.
@category core
export def editor [
  --cd: directory # Set the working directory for the editor session
  --depth (-d): int = 1 # Depth to recurse when expanding glob expressions
  ...rest: glob # Files or glob expressions for the files to edit
]: oneof<nothing, path, list<path>, table<name: path>> -> nothing {
  if $cd != null { cd $cd }
  $in | match ($in | describe) {
    nothing | string | list<any> | list<string> => { }
    _ => { get $.name? | compact }
  } | append ($rest | into string | path expand)
  | flat-map { if ($in | path exists) { } else { glob --depth=$depth $in } }
  | default --empty '.'
  | match ($env | select $.zellij!? $.editor!? $.config.buffer_editor? | compact) {
    {zellij: _} => { zellij-edit ...$in }
    {config: {buffer_editor: $e}} | {editor: $e} => { run-external $e ...$in }
    _ => { error make --unspanned 'unable to detect editor binary' }
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

# Replace the current shell instance with a fresh one.
#
# Optionally, a record can be piped in which will be merged into
# the process environment.
@category shells
export def --env --wrapped reload [
  --erase (-e) # Erase the history (clear without keeping scrollback)
  ...rest: string # Additional arguments for the Nushell invocation
]: oneof<nothing, record> -> nothing {
  dispatch os {linux: {|| reset (if $erase { '-wc' } else { '-w' }) }}
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
  let config: record<link: path, regex: string> = dispatch os {
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
    dispatch os {
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
      | prepend [internal util]
      | str join ::
    }
    | compact --empty
  error make --unspanned $details
}

def get-editor-name []: nothing -> string {
  $env.config.buffer_editor? | default $env.editor!? | default '/usr/bin/nano'
}

def get-editor-pane-id [editor?: string]: nothing -> oneof<nothing, int> {
  zellij action list-panes --json
  | from json
  | where {|pane|
    if $pane.is_suppressed { return false }
    if $pane.title =~ '^(editor$|(E|e)diting:\s)' { return true }
    $pane.pane_command? | $in != null and $in =~ ($editor | default { get-editor-name })
  } | get $.0?.id
}

def zellij-edit [...rest: path]: nothing -> nothing {
  let editor: string = get-editor-name
  # ensures flags are sorted after paths
  let args: list = $rest | sort --reverse
  # if editor pane is detected, focus it so it gets replaced instead of currently focused
  get-editor-pane-id $editor | if ($in | describe) == int { zellij action focus-pane-id $in }
  # count only non-option arguments (currently should be all of them; defense-in-depth)
  match ($rest | where $it !~ '^-+' | length) {
    0 => { error make --unspanned 'no paths were provided' }
    1 => {|p: path ...opts: string| zellij edit --in-place $p ...$opts }
    _ => {|...rest: string|
      # use same prefix to ensure future stacked calls use the same pane regardless of any current
      let name: string = $'Editing: ($rest | first | path basename), ...'
      zellij run --name=($name) --in-place --close-on-exit -- $editor ...$rest
    }
    # capture any errors so they propagate back to the initial caller
  } | do --capture-errors $in ...$args
  # print the terminal identifier string for saliency while still returning `null`
  | print
}

# ——— completions —————————————————————————————————————————————————————————————

def _executables []: [nothing -> record] {
  which
  | where type == external
  | get command
  | path parse
  | get stem
  | into completions
}
