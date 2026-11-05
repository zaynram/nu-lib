# /work/dev/nu/edit/mod.nu

# ——— definitions ——————————————————————————————————————————————————————————————

# Open a file in the default editor or the editor pane of an active Zellij session.
@category core
export def main [
  --cd: directory = . # Set the working directory for the editor session
  --depth (-d): int = 1 # Depth to recurse when expanding glob expressions
  ...rest: glob # Files or glob expressions for the files to edit
]: oneof<nothing, path, list<path>, record, table> -> nothing {
  let items: list<path> = collect --keep-env {||
    cd $cd; $in | append $rest
  } | par-each --keep-order {|it|
      match ($in | describe) {
        glob | string => (into string)
        _ => (get $.name? $.path? $.filename? | default [] | flatten | compact).0?
      } | if $in == null or $in =~ ':\d+$' { return $in } else { path expand }
      | if ($in | path exists) { return $in } else {
        let p: path;
        try { glob --depth=$depth $p } catch { $p }
      }
    } | flatten | compact | default --empty [$env.pwd!]
  let editor: string = get-editor-name
  match ($env.ZELLIJ!? | describe) {
    nothing => {|| run-external $editor ...$items }
    string => {|| with-zellij ...$items }
  } | do --capture-errors $in
  return
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def get-editor-name []: nothing -> string {
  $env.config.buffer_editor? | default $env.editor!? | default '/usr/bin/nano'
}

def get-editor-pane-id [editor?: string]: nothing -> oneof<nothing, int> {
  if $env not-has ZELLIJ { return }
  ^zellij action list-panes --json
  | from json
  | where {|pane|
    if $pane.is_suppressed { return false }
    if $pane.title =~ '^(editor$|(E|e)diting:\s)' { return true }
    $pane.pane_command? | $in != null and $in =~ ($editor | default { get-editor-name })
  } | get $.0?.id
}

def with-zellij [...rest: path]: nothing -> nothing {
  let editor: string = get-editor-name
  # ensures flags are sorted after paths
  let args: list = $rest | sort --reverse
  # if editor pane is detected, focus it so it gets replaced instead of currently focused
  get-editor-pane-id $editor | each { ^zellij action focus-pane-id $in }
  # count only non-option arguments (currently should be all of them; defense-in-depth)
  match ($rest | where $it !~ '^-+' | length) {
    0 => { error make --unspanned 'no paths were provided' }
    1 => {|p: path ...opts: string| zellij edit --in-place $p ...$opts }
    _ => {|...rest: string|
      # use same prefix to ensure future stacked calls use the same pane regardless of any current
      let name: string = $'Editing: ($rest | first | path parse | get $.stem), ...'
      ^zellij run --name=($name) --in-place --close-on-exit -- $editor ...$rest
    }
    # capture any errors so they propagate back to the initial caller
  } | do --capture-errors $in ...$args
  # print the terminal identifier string for saliency while still returning `null`
  | print
}
