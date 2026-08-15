# ——— imports —————————————————————————————————————————————————————————————————

use ../error

# ——— constants ———————————————————————————————————————————————————————————————

export const autoload: path = $nu.vendor-autoload-dirs.2
export const plugins: path = $nu.data-dir | path join plugins (version).version
export const modules: path = $nu.data-dir | path basename --replace nupm/modules
export const scripts: path = $nu.data-dir | path basename --replace nupm/scripts

alias vars = do --ignore-errors { (scope variables | where name == '$vendor').0?.value }
alias rtty = do --ignore-errors { run-external ($autoload | path basename --replace require-tty) | ignore }

# ——— definitions —————————————————————————————————————————————————————————————

# Refresh the `oh-my-posh` prompt configuration.
# Ensures the script is replaced after application updates.
def "init oh-my-posh" []: nothing -> nothing {
  let p: path = $nu.home-dir | path join .config oh-my-posh prompt.json
  oh-my-posh init nu --config $p
  $autoload | path join oh-my-posh.nu | rtty
}

# Refresh the `carapace` completion script.
# Ensures the script contains all configured completions on startup.
def "init carapace" []: nothing -> nothing {
  let p: path = $nu.vendor-autoload-dirs | last | path join carapace.nu
  carapace _carapace nushell | save --force $p
  $p | rtty
}

# Initialize and auto-start the default Zellij session.
export def start-zellij []: nothing -> nothing {
  if $env not-has ZELLIJ and ($env.ZELLIJ_AUTO_START? | into bool --relaxed) {
    let name: string = $env.ZELLIJ_AUTO_SESSION? | default auto
    zellij attach $name --create --force-run-commands
    if ($env.ZELLIJ_AUTO_EXIT? | into bool --relaxed) {
      exit 0 # nu-lint-ignore: exit_only_in_main
    }
  }
}

# Initialize and run configured vendor startup actions.
@category shells
export def --env init []: nothing -> nothing { init oh-my-posh; init carapace }

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
