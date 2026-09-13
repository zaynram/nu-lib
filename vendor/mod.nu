# Utilities and constants for pre-configured or vendored programs and libraries.

# ——— imports —————————————————————————————————————————————————————————————————

use ../error
use ../util "path add"

# ——— constants ———————————————————————————————————————————————————————————————

export const bin: path = if $nu.os-info.name == windows {
  $nu.home-dir | path join AppData Local Microsoft WindowsApps
} else {
  '/opt/homebrew/bin/'
}
export const autoload: path = if $nu.os-info.name == windows {
  $nu.vendor-autoload-dirs.1
} else {
  $nu.vendor-autoload-dirs.2
}
export const plugins: path = $nu.data-dir | path join plugins (version).version
export const modules: path = $nu.data-dir | path basename --replace nupm/modules
export const scripts: path = $nu.data-dir | path basename --replace nupm/scripts

const _path: list = [$bin $scripts]
const _rtty: path = $autoload | path basename --replace require-tty

alias vars = do --ignore-errors { (scope variables | where name == '$vendor').0?.value }
alias rtty = do --ignore-errors {
  if ($_rtty | path exists) { run $_rtty | ignore }
}

# ——— definitions —————————————————————————————————————————————————————————————

# Consume or initialize the vendor environment variables.
@category env
export def --env env [
  --with (-w): record = {}
  # Merge these environment variables into the record, overwriting any existing values
  --load (-l)
  # Load the environment into the current process, if not done so already
  --show (-s)
  # Return the vendor environment, as a record
]: oneof<record, nothing> -> oneof<nothing, record> {
  let e: record = default {} | merge $with | upsert PATH { default $env.PATH | prepend (path) }
  if $load { $e | load-env }
  if $show or not $load { return $e }
}

# Return a list of PATH directories satisfying a condition.
#
# If no predicate is provided, directories in the current environment's PATH will be excluded.
@category path
export def path [
  pred?: closure # Predicate to filter the elements included in the output list
  --all (-a) # Include all directories (cannot be combined with a predicate)
]: nothing -> list {
  $_path | if $all { } else if $pred != null { where $pred } else { difference $env.PATH }
}

const _exts: list = [toml yaml yml json jsonc]

# Refresh the `oh-my-posh` prompt configuration.
@category shells
export def "init oh-my-posh" [
  --config: path
  # Path to the Oh-My-Posh prompt configuration file (defaults to `$env.POSH_CONFIG` if set)
]: nothing -> nothing {
  match ($config | default --empty $env.POSH_CONFIG?) {
    null => { oh-my-posh init nu }
    $p if ($p | path type) != file => { error make --unspanned $"file not found: '($p)'" }
    $p if ($p | path parse).extension not-in [toml yaml yml json jsonc] => { error make --unspanned $"invalid configuration file: '($p)'" }
    $p => { oh-my-posh init nu --config=($p) }
  }

  let f: path = $autoload | path join oh-my-posh.nu
  $f | run $_rtty | ignore
  if $nu.os-info.name == windows {
    open --raw $f
    | collect { lines | take until { str contains '$_omp_executable upgrade' } | str join (char newline) }
    | save --force $f
  }
}

# Initialize and auto-start the default Zellij session.
@category shells
export def start-zellij []: nothing -> nothing {
  if $env not-has ZELLIJ and ($env.ZELLIJ_AUTO_START? | into bool --relaxed) {
    let name: string = $env.ZELLIJ_AUTO_SESSION? | default auto
    zellij attach $name --create --force-run-commands
    if ($env.ZELLIJ_AUTO_EXIT? | into bool --relaxed) {
      exit 0 # nu-lint-ignore: exit_only_in_main
    }
  }
}

# Navigate or return a configured vendor directory.
@category filesystem
export def --env main [
  target?: cell-path@_cell-paths # The cell-path of the directory to target
  --get (-g) # Return the path as a string instead of navigating to it
]: nothing -> oneof<nothing, path, record> {
  if $target == null { return (vars) }
  let dir: oneof<nothing, path> = vars | get --ignore-case --optional $target
  if $get { return $dir } else if $dir != null { cd $dir } else {
    error wrap --code=vendor::dir::invalid_target $"no property matches '($target)'"
  }
}

# ——— completions —————————————————————————————————————————————————————————————

def _cell-paths []: nothing -> list { vars | columns }
