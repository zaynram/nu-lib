# Open files in the configured editor, or in an editor pane when running inside Zellij.

# ——— definitions ——————————————————————————————————————————————————————————————

# Open a file in the default editor or the editor pane of an active Zellij session.
#
# Items come from the arguments and the pipeline input (paths, or records/tables with a `name`, `path` or
# `filename` column) and resolve against `--cd`: `file:line` items pass through verbatim, existing paths and
# paths without glob characters are expanded (so the editor creates a new file), and glob patterns expand to
# their sorted matches, `--depth` levels deep. When nothing resolves (no items, or only globs without matches)
# the editor opens `--cd`.
#
# The editor is `$env.config.buffer_editor` (a program, or a list of the program and its arguments), else
# `$env.EDITOR`, else `/usr/bin/nano`, and runs in `--cd`. Inside Zellij (`$env.ZELLIJ` is set) one file opens
# with `zellij edit --in-place` and several with `zellij run --in-place` in a pane named
# `Editing: <first stem>, ...`; an existing editor pane is focused first so that it is the one replaced.
@category core
export def main [
  --cd: directory = . # The working directory for the editor session; items resolve against it
  --depth (-d): int = 1 # Depth to recurse when expanding glob expressions
  ...rest: glob # Files or glob expressions for the files to edit
]: oneof<nothing, path, list<path>, record, table> -> nothing {
  let input: any = $in
  cd $cd
  let items: list<string> = $input
    | append $rest
    | each {|it| $it | resolve-item $depth }
    | flatten
    | default --empty [$env.PWD]
  if $env.ZELLIJ? == null {
    let editor: list<string> = get-editor
    run-external ($editor | first) ...($editor | skip 1) ...$items
  } else {
    with-zellij ...$items
  }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# The paths an input item stands for (see `main`).
def resolve-item [depth: int]: oneof<nothing, glob, string, record> -> list<string> {
  let item: oneof<nothing, string> = match ($in | describe) {
    glob | string => ($in | into string)
    _ => ($in | get --optional $.name $.path $.filename | compact | get --optional 0)
  }
  if $item == null { return [] }
  if $item =~ ':\d+$' { return [$item] }
  if ($item | path exists) or $item !~ '[*?\[\]{}]' { return [($item | path expand)] }
  glob --depth=$depth $item | sort
}

# The editor command: `$env.config.buffer_editor`, `$env.EDITOR` or `/usr/bin/nano`, as program and arguments.
def get-editor []: nothing -> list<string> {
  [($env.config.buffer_editor? | default --empty $env.editor!? | default --empty '/usr/bin/nano')] | flatten
}

# The id (`terminal_<n>`) of a visible terminal pane that looks like an editor: named `editor` or
# `Editing: …`, or running the editor program.
def get-editor-pane-id [program: string]: nothing -> oneof<nothing, string> {
  ^zellij action list-panes --json --command
  | from json
  | where {|pane|
    if $pane.is_plugin or $pane.is_suppressed { return false }
    if $pane.title =~ '^(editor$|(E|e)diting:\s)' { return true }
    $pane.pane_command? | $in != null and $program in $in
  } | get --optional $.0.id
  | if $in != null { $"terminal_($in)" }
}

def with-zellij [...items: string]: nothing -> nothing {
  let editor: list<string> = get-editor
  # focus an existing editor pane, so that it is the one replaced instead of the current one
  get-editor-pane-id ($editor | first | path basename) | each {|id| ^zellij action focus-pane-id $id }
  match ($items | length) {
    0 => { error make --unspanned 'no paths were provided' }
    1 => { ^zellij edit --in-place --cwd $env.PWD ($items | first) }
    _ => {
      # the same name prefix lets later calls find and replace this pane
      let name: string = $'Editing: ($items | first | path parse | get $.stem), ...'
      ^zellij run --name=($name) --in-place --close-on-exit --cwd $env.PWD -- ...$editor ...$items
    }
  }
  # print the pane identifier for saliency while still returning `null`
  | print
}
