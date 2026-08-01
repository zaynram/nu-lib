# ——— imports —————————————————————————————————————————————————————————————————

use ../error

# ——— constants ———————————————————————————————————————————————————————————————

const var: record = {
  autoload: $nu.vendor-autoload-dirs.2?
  plugins: ($nu.data-dir | path join plugins (version).version)
  modules: ($nu.data-dir | path basename --replace nupm/modules)
}

export const autoload: oneof<nothing, path> = $var.autoload
export const plugins: path = $var.plugins
export const modules: path = $var.modules

# ——— definitions —————————————————————————————————————————————————————————————

# Refresh the `oh-my-posh` prompt configuration.
# Ensures the script is replaced after application updates.
def "init oh-my-posh" []: nothing -> nothing {
  let p: path = $nu.default-config-dir
    | path basename --replace oh-my-posh
    | path join prompt.json
  if not ($p | path exists) { oh-my-posh init nu --config $p }
}

# Refresh the `carapace` completion script.
# Ensures the script contains all configured completions on startup.
def "init carapace" []: nothing -> nothing {
  let p: path = $nu.vendor-autoload-dirs | last | path join carapace.nu
  carapace _carapace nushell | save --force $p
}

# Initialize and auto-start the default Zellij session.
def "init zellij" []: nothing -> nothing {
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
export def --env init []: nothing -> nothing { init oh-my-posh; init carapace; init zellij }

# Navigate or return a configured vendor directory.
@category filesystem
export def main [
  target?: cell-path@_cell-paths # The cell-path of the directory to target
  --get (-g) # Return the path as a string instead of navigating to it
]: nothing -> oneof<nothing, path, record> {
  if $target == null { return $var }
  let dir: oneof<nothing, path> = $var | get --ignore-case --optional $target
  if $get { return $dir } else if $dir != null { cd $dir } else {
    error wrap --code=vendor::dir::invalid_target $"no property matches '($target)'"
  }
}

# ——— completions —————————————————————————————————————————————————————————————

def _cell-paths []: nothing -> list { $var | columns }
