# Custom external completion provider with configurable dispatch rules.

use ../mod.nu "into spans"

# Commands to complete using `fish` by default.
const FISH: list<string> = [nu git td asdf]

# ——— submodules —————————————————————————————————————————————————————————————

module fish-complete {
  # Submodule wrapping commands for querying completions from `fish` shell.

  # ——— constants ————————————————————————————————————————————————————————————

  const CHAR: string = r#'[\\,\[\]() '"`]'#
  const EXPR: string = '^\s*(?<value>\w+|-{1,2}[\w+\-]*)*={0,1}\w*\s*$'

  # ——— environment ——————————————————————————————————————————————————————————

  export-env {
    if $env.ENV_CONVERSIONS not-has fish_commands {
      $env.ENV_CONVERSIONS.fish_commands! = {
        to_string: {|v| $v | str join (char esep) }
        from_string: {|s| $s | split row (char esep) | compact | uniq }
      }
    }
  }

  # ——— exports ——————————————————————————————————————————————————————————————

  # Deserialize completions provided by `fish` into Nushell values.
  @category strings
  export def parse-output []: string -> table<value: string, description: string> {
    from tsv --flexible --noheaders --no-infer
    | rename value description
    | update value {|row|
      if not ($in | path exists) or $row.value !~ $CHAR { return $in } else { }
      | if $in starts-with ~ { path expand --no-symlink } else { }
      | $'"($in | str replace --all "\"" "\\\"")"'
    }
  }

  # Complete a commandline using `fish` completions.
  @category shells
  export def main [
    buffer: string
  ]: list<string> -> oneof<list<string>, table<value: string>> {
    let final: oneof<nothing, string> = skip | last
    $buffer | str replace --all "'" "\\'"
    | fish --command $"complete '--do-complete=($in)'"
    | parse-output
    | if $final == null { } else {
      where value starts-with $final and value != $final
    }
  }
}

export use fish-complete

module carapace-complete {
  # Submodule for querying completions from `carapace`.

  # ——— constants ————————————————————————————————————————————————————————————

  const PATH: list<path> = [($nu.default-config-dir | path basename --replace carapace/bin)]

  # ——— environment ——————————————————————————————————————————————————————————

  export-env {
    [[key value]; [CARAPACE_LENIENT '1'] [CARAPACE_BRIDGES 'zsh,fish,bash,complete,argcomplete,clap']]
    | difference ($env | select $.CARAPACE_LENIENT!? $.CARAPACE_BRIDGES!? | transpose key value)
    | if ($env.path! | intersect $PATH | is-empty) { [...$in {key: PATH value: ($PATH ++ $env.path!)}] } else { }
    | if $in != [] { transpose --ignore-titles --header-row --as-record | load-env }
  }

  # ——— exports ——————————————————————————————————————————————————————————————

  # Return the `CARAPACE_SHELL_[FUNCTIONS|BUILTINS]` variables `carapace` uses during completions.
  @category env
  export def runtime-env []: nothing -> record {
    help commands
    | select name category
    | update name { split row (char sp) | first }
    | uniq-by name
    | update category { match $in { "" => 'CARAPACE_SHELL_FUNCTIONS' _ => 'CARAPACE_SHELL_BUILTINS' } }
    | group-by --prune --to-table category
    | update items { get name }
    | transpose --ignore-titles --header-row --as-record
  }

  # Complete a commandline using `carapace`.
  @category shells
  export def main [
    name: string
    # The name of the command to get completions for
    --shell (-s): string@_shells = 'nushell'
    # An optional override for the shell name to use for the `carapace` invocation
    --deserialize (-d): closure
    # Closure to run to hydrate `carapace` output; necessary when using a shell besides `nushell` / `fish`
  ]: list<string> -> oneof<list<string>, table<value: string>> {
    let spans: list;
    let parse: closure = $deserialize
      | default { match $shell { nushell => {|| from json } fish => {|| fish-complete parse-output } } }
      | default { {|| lines | split row (char sp) | first } } # best-effort selection of first word per line when unsure
    with-env (runtime-env) { carapace $name $shell ...$spans | do --ignore-errors $parse | default [] }
  }

  # ——— completions ——————————————————————————————————————————————————————————

  def _shells []: nothing -> list { [bash bash-ble cmd-clink elvish fish ion nushell] }
}

export use carapace-complete

# ——— exports ————————————————————————————————————————————————————————————————

# Configure completions using `carapace` and `fish` as providers.
# Fallback providers can be passed with `--default` or by setting a custom completer before invoking this function.
@category core
export def --env set-completer [
  --default (-d): closure
  # Fallback closure to run with `$buffer` as a positional when completions are empty
]: nothing -> nothing {
  # Initialize defaults if the value is `null` when setting the completer;
  # this is intentional so that an empty list is treated as "don't use fish completions"
  if $env.fish_commands? == null { $env.fish_commands = $FISH }
  let default: oneof<nothing, closure> = $default | default { $env.config.completions.external.completer? }
  $env.config.completions.external.completer = {|buffer: string|
    $buffer | into spans --unalias | match $in.0? {
      $0 if ($env.fish_commands? | default $FISH) has $0 => { fish-complete $buffer }
      $0 => { carapace-complete $0 }
    } | if $in == [] and [$env.config.completions.external.completer? null] not-has $default {
      do --ignore-errors $default $buffer | default []
    } else { }
  }
}

# Complete a command using the configured external custom completer.
@category core
@example 'test external completions for the string "git stat"' { run-completer 'git stat' } --result=["status "]
export def run-completer [
  buffer: string
  # Test completion evaluation foe the given buffer (pipeline input is ignored when this is present)
]: oneof<nothing, string, list<string>> -> oneof<nothing, table> {
  if $env.config.completions.external.completer? == null { set-completer }
  $in | default --empty $buffer | each $env.config.completions.external.completer
}
