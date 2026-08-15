# Utilities and optimization methods for clean separation of the Windows host environment when working in the WSL Debian environment.

# nu-lint-ignore-file: kebab_case_commands, missing_output_type

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  $env.PATH
  | split list --regex '\s*^/mnt/[[:alpha:]]{1}/.+' --split=before
  | do --env {|home: record|
    load-env {
      USERPROFILE: ($home | path join)
      PATH: ($in | first)
      WINPATH: ($in | skip 1 | flatten)
    }
  } {parent: /mnt/c/Users stem: $env.USER extension: ''}
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Locate a Windows application and return the path(s).
@category core
export def --wrapped "win which" [
  name: string # The name of the application to search for
  --unwrap (-u) # Return the first entry only
  ...rest: string # Additional arguments to pass to `where.exe`
]: nothing -> oneof<list<path>, path, nothing> {
  with-env {PATH: (require-var winpath)} {
    /mnt/c/Windows/system32/where.exe $name ...$rest
    | lines
    | compact --empty
    | append (which $name --all | get --optional path | default [])
    | each { /usr/bin/wslpath -u $in | into string }
    | if $unwrap { first } else { $in }
  }
}
# Change to the windows user's desktop directory
@category filesystem
export def desk --env [
  ...segments: string # Path segments to join to the resolved desktop directory
  --return (-r) # Return the resolved path instead of changing directories
]: nothing -> oneof<nothing, directory> {
  let target: path = require-var userprofile --validate { path type | $in == dir }
    | path join desktop ...$segments
  if $return { return $target } else { goto-target $target }
}

# Construct a windows path from the input path
@category filesystem
export def --env "win path" [
  ...segments: string
  --user (-u) # Use the user's home directory as the base path
  --mount (-m): string = c # Use this mounted drive as the base path
  --cd (-c) # Set the working directory to the windows path
]: oneof<path, nothing> -> oneof<path, nothing> {
  let target: path = if not $user { [/ mnt $mount] } else {
    require-var userprofile --validate { path type | $in == dir }
  } | path join ...$segments
  if not $cd { return $target } else { goto-target $target }
}

# Invoke an executable on the windows PATH.
#
# Invocation may be provided inline as `<command> ...<args>` or
# as a closure from pipeline input stream.
@category filesystem
export def --env --wrapped "win run" [
  executable?: string # External command to invoke with Windows PATH
  ...rest: string # Arguments to pass to the executable
  --nu-help # Show the native help message for this command (`--help` is passed to invocation)
  --base-env: record = {} # Base environment to inject the Windows PATH into
]: oneof<closure, nothing> -> any {
  if $nu_help { help "win run" | return $in }
  if $in == null and $executable == null {
    error make --unspanned "no command or closure was provided"
  }
  let path: list<path> = [
    ...($base_env | get --ignore-case --optional path | default [])
    ...(require-var winpath --validate { ($in | describe) =~ list })
    ...($env | get --ignore-case --optional path | default [])
  ] | uniq
  let vars: record = $base_env | reject --ignore-case --optional path | merge {PATH: $path}
  let main: closure = $in | default {
      let name: string = match ($executable | path parse | get extension) {
        exe | cmd | bat | ps1 => $executable
        _ => { win which --unwrap $executable }
      }
      if $name == null { error make --unspanned $"command not found: ($executable)" }
      return { run-external $name ...$rest }
    }
  with-env $vars { do --env --capture-errors $main }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def require-var [
  name: string
  --validate: closure # Value is provided as a positional and as pipeline input
]: nothing -> any {
  let check = $validate | default { { $in != null } }
  let value = $env | get --optional --ignore-case $name
  let valid = $value | do --ignore-errors $check $value | into bool --relaxed
  if $valid { return $value } else {
    error make --unspanned $"invalid value for environment variable '($name)'"
  }
}

def bad-target [
  label: record<text: string, span: string>
]: oneof<error, nothing> -> error {
  error make --unspanned {
    msg: $"($label.text) is not a valid directory"
    label: $label
    inner: ([$in] | compact)
  }
}

def --env goto-target [
  target: directory
  --text: string = target
]: nothing -> nothing {
  try { cd $target } catch {
    bad-target {text: $text span: (metadata $target).span}
  }
}
