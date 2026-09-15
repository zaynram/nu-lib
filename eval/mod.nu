#!/usr/bin/env -S nu --stdin
# Hybrid module/script for evaluating Nushell code in the current terminal REPL.

# nu-lint-ignore-file: script_export_main

# ——— imports ——————————————————————————————————————————————————————————————————

use std/iter flat-map

# ——— constants ————————————————————————————————————————————————————————————————

export const EOL: string = char newline

# ——— definitions ——————————————————————————————————————————————————————————————

# Evalute a Nushell script or module code in the active terminal REPL.
@category shell
export def main [
  ...files: path@_default-mods-and-scripts
  # The files to evaluate the code from
  --overlay (-o) = true
  # Create isolated overlays for each file (name based on path; prefixed with `__`)
  --errors (-e)
  # Whether to raise runtime and parser errors when evaluating the files
  --resolve (-r)
  # Whether to raise errors for unresolved file paths
]: oneof<nothing, path, list<path>> -> nothing {
  let queue: table = append $files
    | path expand --strict=$resolve
    | wrap path
    | insert name {|row|
      match ($row.path | path parse) {
        {parent: $p stem: mod extension: nu} => { $p | path basename }
        {stem: $s extension: nu} => $s
      } | prepend __ | str join
    } | insert code {|row|
      let psep: string = char psep
      let find: string = [
        '(?<indent>\s*)(?<keyword>use|source-env)\s+..'
        '(?<relative>\w+)(?<rest>\s*)'
      ] | str join $psep
      let replace: string = match ($row.path | path parse) {
        {parent: $p stem: mod extension: nu} => { $p | path dirname }
        {parent: $p stem: $s extension: nu} => $p
      } | $'${indent}${keyword} ($in)($psep)${relative}${rest}'
      try { open --raw $row.path } catch { if $errors { error make --unspanned } }
      | str replace --all --regex $find $replace
    } | compact code

  for row in $queue {
    # When `ignore_space_prefixed` is enabled, we'll avoid polluting the history
    if $env.config.history.ignore_space_prefixed { ' ' } else { '' }
    | if $overlay { append $"overlay new ($row.name)" } else { }
    | append $row.code
    | if $overlay { append $"overlay hide ($row.name)" } else { }
    | str join $EOL
    | commandline edit --replace --accept $in
    sleep 100ms # Small delay for cases where the REPL needs time to execute the code
  }

  $queue.name | to nuon --no-commas
  | if $overlay {
    append $'clear --keep-scrollback; overlay list | where name in ($in)'
  } else { } | prepend '' | str join $EOL
  | commandline edit --insert --accept $in
}

# ——— completions ——————————————————————————————————————————————————————————————

def _default-mods-and-scripts []: nothing -> oneof<record, list> {
  $env.NU_LIB_DIRS?
  | default []
  | where ($it | path type) == dir
  | flat-map {|d|
    glob --no-dir --depth=3 $'($d)/**/*.nu' --exclude=[
      **/nupm/**
      **/nupm+/**
      **/tests/*.nu
      **/test.nu
    ]
    | str replace $env.PWD '.'
    | wrap value
    | insert description {|row|
      $row.value
      | if $in ends-with $"(char psep)mod.nu" { path dirname } else { }
      | path basename
    }
  } | uniq-by value | insert type directory
}
