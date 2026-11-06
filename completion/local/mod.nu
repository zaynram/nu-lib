# Host-dependent completion: `completion` plus external completers backed by `fish` and `carapace`.
#
# Configuration-dependent (needs `fish`/`carapace` on PATH and mutates `$env.config`); the abstract builders
# live in `completion`, re-exported here so one import provides both.
#
# A direct `use completion/local` (any form) runs the `export-env` below. A re-export (`export use`) does not, so
# a barrel that re-exports this module must also trigger it, e.g. `export-env { use completion/local }`.

# ——— imports ——————————————————————————————————————————————————————————————————

export use ../mod.nu *

# ——— constants ————————————————————————————————————————————————————————————————

# Commands to complete using `fish` by default (`$env.fish_commands` overrides).
const FISH: list<string> = [nu git td asdf]

# Variables `carapace` reads; set only when absent.
const CARAPACE: record = {
  CARAPACE_LENIENT: '1'
  CARAPACE_BRIDGES: 'zsh,fish,bash,complete,argcomplete,clap'
}

# Where `carapace` keeps its user shims, prepended to PATH: `<config>/carapace/bin`.
const CARAPACE_BIN: path = $nu.default-config-dir | path basename --replace carapace/bin

# ——— submodules ———————————————————————————————————————————————————————————————

module fish-complete {
  # Query completions from the `fish` shell.

  # ——— constants ————————————————————————————————————————————————————————————

  # A completion value containing one of these needs quoting to be a single nushell argument.
  const CHAR: string = r#'[\\,\[\]() '"`]'#

  # ——— exports ——————————————————————————————————————————————————————————————

  # Deserialize completions provided by `fish` into Nushell values.
  # - a leading `~` is always expanded
  # - a value that is an existing path containing a space, quote, backtick, comma, bracket, parenthesis or
  #   backslash is double-quoted (with `\` and `"` escaped)
  @category strings
  export def parse-output []: string -> table<value: string> {
    read-tsv | hydrate
  }

  # Complete a commandline using `fish` completions.
  # The pipeline input is the commandline's spans. When a final span (after the command name) is given, only
  # values that extend it are kept, compared before `parse-output` expands or quotes them.
  @category shells
  export def main [
    buffer: string
    # The commandline to complete
  ]: list<string> -> table<value: string> {
    let final: oneof<nothing, string> = skip | last
    # a fish single-quoted string: `\` and `'` are the only escapes
    $buffer | str replace --all --regex "([\\\\'])" '\$1'
    | ^fish --command $"complete '--do-complete=($in)'"
    | read-tsv
    | if $final == null { } else {
      where value starts-with $final and value != $final
    }
    | hydrate
  }

  # ——— helpers ——————————————————————————————————————————————————————————————

  # fish's `value<TAB>description` lines as rows, values verbatim (`description` is absent on lines without one).
  def read-tsv []: string -> table<value: string> {
    from tsv --flexible --noheaders --no-infer | rename value description
  }

  # Make each value usable as a nushell argument (see `parse-output`).
  def hydrate []: table<value: string> -> table<value: string> {
    update value {
      if $in starts-with '~' { path expand --no-symlink } else { }
      | if ($in | path exists) and $in =~ $CHAR {
        $'"($in | str replace --all --regex '([\\"])' '\$1')"'
      } else { }
    }
  }
}

export use fish-complete

module carapace-complete {
  # Query completions from `carapace`.

  # ——— exports ——————————————————————————————————————————————————————————————

  # The `CARAPACE_SHELL_FUNCTIONS`/`CARAPACE_SHELL_BUILTINS` variables `carapace` reads during completion:
  # newline-separated first words of the commands in scope (custom commands are functions, the rest builtins).
  @category env
  export def runtime-env []: nothing -> record {
    help commands
    | select name command_type
    | update name { split row (char sp) | first }
    | uniq-by name
    | insert key {|row| if $row.command_type == custom { 'CARAPACE_SHELL_FUNCTIONS' } else { 'CARAPACE_SHELL_BUILTINS' } }
    | group-by --prune --to-table key
    | update items { get name | str join (char nl) }
    | transpose --ignore-titles --header-row --as-record
  }

  # Complete a commandline using `carapace`.
  # The pipeline input is the commandline's spans, including the command name. A failing `carapace` or
  # deserializer yields `[]`.
  @category shells
  export def main [
    name: string
    # The name of the command to get completions for
    --shell (-s): string@_shells = 'nushell'
    # An optional override for the shell name to use for the `carapace` invocation
    --deserialize (-d): closure
    # Closure to run to hydrate `carapace` output; necessary when using a shell besides `nushell` / `fish`
    --runtime-env (-r): record
    # The `CARAPACE_SHELL_*` variables to run under (default: computed now with `runtime-env`)
  ]: list<string> -> oneof<list<string>, table<value: string>> {
    let spans: list;
    let parse: closure = $deserialize
      | default { match $shell { nushell => {|| from json } fish => {|| fish-complete parse-output } } }
      | default { {|| lines | each { split row (char sp) | first } } } # best-effort: the first word of each line
    let found = with-env ($runtime_env | default { runtime-env }) {
      try { ^carapace $name $shell ...$spans | do $parse } catch { [] }
    }
    $found | default []
  }

  # ——— completions ——————————————————————————————————————————————————————————

  def _shells []: nothing -> list<string> {
    [bash bash-ble cmd-clink elvish fish ion nushell oil powershell tcsh xonsh zsh]
  }
}

export use carapace-complete

# ——— helpers ——————————————————————————————————————————————————————————————————

# The external completer `set-completer` installs, with `default` as its fallback.
# `carapace-complete` recomputes `runtime-env` (~5 ms, every command in scope) on each completion: that is never
# stale, whereas a cached snapshot keyed on `scope commands | length` cost more to check (~7 ms) than the recompute
# it saved, and missed a command set that changed without changing its count.
def completer [default: oneof<nothing, closure>]: nothing -> closure {
  {|buffer: string, place?: record|
    let spans: list<string> = if $place == null { $buffer } else { $place.command | str join (char sp) }
      | into spans --unalias
    $spans | match $spans.0? {
      null => { [] }
      $0 if ($env.fish_commands? | default $FISH) has $0 => { fish-complete ($spans | str join (char sp)) }
      $0 => { carapace-complete $0 }
    } | if $in == [] and [$env.config.completions.external.completer? null] not-has $default {
      do --ignore-errors $default $buffer | default []
    } else { }
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Configure completions using `carapace` and `fish` as providers.
# The command under the cursor (its first word resolved through aliases) picks the provider: commands listed in
# `$env.fish_commands` (default `[nu git td asdf]` when unset; `[]` disables fish) go to `fish`, everything else
# to `carapace`. Fallback providers can be passed with `--default` or by setting a custom completer before
# invoking this function: the fallback runs with the buffer when the provider returns nothing.
# A completer this command installed is never taken as the fallback: calling it again without `--default` keeps
# the installed completer (and its fallback) as it is.
# The completer takes `buffer` and an optional `place`: Nushell hands it both by name, so `place.command` (the
# command after a pipe, `;` or inside a closure) is completed; called with a buffer alone, the whole buffer is.
@category core
export def --env set-completer [
  --default (-d): closure
  # Fallback closure to run with `$buffer` as a positional when completions are empty
]: nothing -> nothing {
  # Initialize defaults if the value is `null` when setting the completer;
  # this is intentional so that an empty list is treated as "don't use fish completions"
  if $env.fish_commands? == null { $env.fish_commands = $FISH }
  let current: oneof<nothing, closure> = $env.config.completions.external.completer?
  let fallback: oneof<nothing, closure> = if $default != null { $default } else { $current }
  let built: closure = completer $fallback
  # closures compare equal when they come from the same literal: this recognizes any completer `completer` built
  let installed: bool = $current != null and $current == $built
  if $installed and $default == null { return }
  $env.config.completions.external.completer = $built
}

# Complete a command using the configured external custom completer (installing it for this call if unset).
# The completer is called as Nushell would at the end of the buffer: with `buffer` and `place` as positionals.
# Each pipeline input string is completed when no `buffer` is given.
@category core
@example 'test external completions for the string "git stat"' { run-completer 'git stat' }
export def run-completer [
  buffer?: string
  # The commandline to complete (pipeline input is ignored when this is present)
]: oneof<nothing, string, list<string>> -> oneof<nothing, table, list<table>> {
  let input: oneof<nothing, string, list<string>> = $in
  if $env.config.completions.external.completer? == null { set-completer }
  let completer: closure = $env.config.completions.external.completer
  let run: closure = {|line: string|
    let at: record = $line | commandline complete --input
    do $completer $at.buffer $at.place
  }
  if $buffer != null { do $run $buffer } else { $input | each $run }
}

# ——— environment ——————————————————————————————————————————————————————————————

# Runs on every direct `use`; idempotent: values already present are kept, and PATH gains the carapace bin once.
export-env {
  if ($env.ENV_CONVERSIONS? | default {}) not-has fish_commands {
    $env.ENV_CONVERSIONS = $env.ENV_CONVERSIONS? | default {} | insert fish_commands {
      to_string: {|v| $v | str join (char esep) }
      from_string: {|s| $s | split row (char esep) | compact | uniq }
    }
  }
  load-env ($CARAPACE | reject --optional ...($env | columns))
  if $CARAPACE_BIN not-in $env.path! {
    load-env {PATH: ($env.path! | prepend $CARAPACE_BIN)}
  }
}
