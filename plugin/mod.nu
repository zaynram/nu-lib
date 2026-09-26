# Install Nushell plugins from GitHub repositories.

const REGEX: record = {
  remote: `^(?<owner>\w[\w.-]*)/(?<name>\w[\w.-]*)$`
  local: `^nu_plugin_(?<name>\w[\w.-]*)$`
}

# Install a plugin using cargo and automatically register it.
@category plugin
export def install [
  plugin: string # Specifier for the plugin (`nu_plugin_<name>` or `<owner>/<name>`)
]: nothing -> nothing {
  let git: bool = not ($plugin starts-with nu_plugin)
  let regex: string = $REGEX | if $git { get $.remote } else { get $.local }
  let name: oneof<nothing, string> = $plugin | parse --regex $regex | into record | get $.name?
  if $name == null { error make --unspanned $"unable to parse source information from '($plugin)'" }
  let path: path = match ($env | select $.cargo_home!? $.xdg_data_home!? | compact) {
    {cargo_home: $c} => $c
    {xdg_data_home: $x} => (glob --no-file --no-symlink --depth=1 $"($x)/{.cargo,cargo}").0?
  } | default ($nu.home-dir | path join .cargo)
    | if ($in | path exists) { } else { error make --unspanned 'unable to resolve CARGO_HOME directory' }
    | path join bin $name
  let args: list = if $git { [--git $'https://github.com/($plugin).git'] } else { [$plugin] }
  do --capture-errors { ^cargo install ...$args }
  | complete
  | if $in.exit_code != 0 {
    error make {
      msg: "`cargo install` exited with non-zero exit code"
      code: `common::plugin::external_cargo_error`
      help: $"[stdout]\n($in.stdout)\n[stderr]\n($in.stderr)"
    }
  } else {
    try { plugin add $path } catch {
      error make {
        msg: 'unable to register plugin'
        code: `common::plugin::plugin_builtin_error`
        label: {text: plugin span: (metadata $plugin).span}
        help: $"ensure directory '($path)' contains the '($name)' binary"
      }
    }
  }
}
