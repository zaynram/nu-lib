const REGEX: record = {
  gh-repo: `^(?<owner>[\w.-]+)/(?<name>[\w.-]+)$`
  nu-plugin: `^nu_plugin_(?<name>[\w.-]+)$`
}

# Install a plugin using cargo and automatically register it.
@category plugin
export def install [
  plugin: string # Specifier for the plugin (`nu_plugin_<name>` or `<owner>/<name>`)
]: nothing -> nothing {
  let mode: record<id: string, regex: string> = $REGEX
    | transpose id regex
    | where $plugin =~ $it.regex
    | first
    | if $in == null { error make --unspanned 'plugin name or git is required' } else { }
  let name: string = $plugin | parse $mode.regex | into record | get name
  let path: path = $env.CARGO_HOME?
    | default { $nu.home-dir | path join .cargo }
    | path join bin $name
  let args: list<string> = match $mode.id {
    gh-repo => [--git $'https://github.com/($plugin).git']
    nu-plugin => [$plugin]
  }

  cargo install ...$args out+err>|
  | complete
  | if $in.exit_code != 0 {
    error make {
      msg: "`cargo install` exited with non-zero exit code"
      code: `common::plugin::external_cargo_error`
      help: $"[output]\n($in.stdout)"
      label: {text: args span: (metadata $args).span}
    }
  }

  try { plugin add $path } catch {
    error make {
      msg: 'unable to register plugin'
      code: `common::plugin::plugin_builtin_error`
      label: {text: plugin span: (metadata $plugin).span}
      help: $"ensure directory '($path)' contains the '($name)' binary"
    }
  }
}
