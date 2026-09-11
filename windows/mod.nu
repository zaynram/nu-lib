# Utilities and optimization methods for clean separation of the Windows host environment when working in the WSL Debian environment.

# nu-lint-ignore-file: kebab_case_commands, missing_output_type

const _save: path = $nu.data-dir | path join windows_env.msgpack

# ——— aliases ——————————————————————————————————————————————————————————————————

# Run the PowerShell 7 executable.
export alias pwsh = /mnt/c/progra~1/PowerShell/7/pwsh.exe
# Run a command with PowerShell 7.
export alias "pwsh x" = pwsh -nop -noni -c
# Run the Powershell Core executable.
export alias powershell = /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
# Run a comand with Powershell Core.
export alias "powershell x" = powershell -nop -noni -c
# Convert Windows path(s) to a UNIX path(s).
export alias "path as-posix" = each {||
  if $in starts-with / { $'//wsl.localhost/($env.WSL_DISTRO_NAME)/($in)' } else { }
  | try { wslpath -u $in }
}
# Convert UNIX path(s) to a Windows path(s).
export alias "path as-windows" = each {|| try { wslpath -m $in } }

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  const RE: string = '[[:punct:]]{0,1}/mnt/[[:alpha:]]{1}/.+/{0,1}[[:punct:]]{0,1}'
  if $env not-has WINPATH {
    $env.PATH?
    | split row (char esep)
    | flatten
    | reduce --fold={PATH: [] WINPATH: []} {|it acc|
      let c: cell-path = if $it =~ $RE { $.WINPATH } else { $.PATH }
      $acc | update $c { append $it | uniq }
    }
  } | default {}
  | if $env not-has WSL_DISTRO_NAME {
    insert WSL_DISTRO_NAME { sys host | get name | split words | first }
  } else if ($in | is-not-empty) { }
  | load-env
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Run a command on the Windows PATH, if it exists.
export def --wrapped "win run" [
  name: string
  # The name of the application to run
  ...rest: string
  # Arguments to pass through to the application if it resolves
]: any -> any {
  win which $name | match ($in | describe) {
    string => { run-external $in ...$rest }
    nothing => { error make --unspanned $"command not found: '($name)'" }
    $t => { error make --unspanned $"unexpected return type: `win which` -> '($t)'" }
  }
}

# Locate a command on the Windows host.
@category platform
export def --wrapped "win which" [
  --all (-a)
  # Return all paths matching the application names
  ...names: string
  # The application names to query locations of
]: nothing -> oneof<nothing, path, list<path>, record> {
  let where: closure = {|a: string|
    try { /mnt/c/Windows/System32/where.exe $a | lines }
    | default []
    | str trim --right
    | path as-posix
    | if $all { } else { first }
  }
  match ($names | length) {
    0 => { return }
    1 => { do $where $names.0 }
    _ => { $names | reduce --fold={} {|it acc| upsert $it { do $where $it } } }
  }
}

# Utilize the full Windows environment for a single command or load it into the session.
@category environment
export def --env "win env" [
  --exec (-e): closure
  # Closure to run with the Windows environment loaded temporarily (overrides other flags)
  --load (-l)
  # Load the variables into the process environment instead of returning them
  --path (-p): string@[merge overwrite] = merge
  # Controls whether the PATH value merges the current process PATH or not
  --vars (-v): list<cell-path>@[[$.PATH] [$.PATHEXT] [$.USERPROFILE]] = [$.PATH $.PATHEXT $.USERPROFILE]
  # The variables to include in the environment
  --reset (-r)
  # Force invalidate any cached environment data
]: oneof<nothing, record> -> oneof<nothing, record, any> {
  let i: record = default {}
  if not $reset { try { open $_save | from msgpack } }
  | default --empty {
    let e: record = $env.WINPATH?
      | default --empty { powershell x '$env:PATH' | split row ';' | where $it !~ '%\w+%' | path as-posix }
      | match $path {
        merge => { prepend $env.PATH }
        overwrite => { }
        _ => { error make --unspanned $"invalid value for `--path`: '($path)'" }
      } | {PATH: ($in | uniq)}
      | insert USERPROFILE { $env.USERPROFILE? | default --empty $"/mnt/c/Users/($env.USER)" }
      | insert PATHEXT { $env.PATHEXT? | default --empty '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.CPL' }
    $e | to msgpack --serialize | save --force $_save
    return $e
  } | merge deep --strategy=prepend $i
  | select --optional ...$vars
  | compact
  | match ($exec | describe) {
    nothing if not $load => { }
    nothing => { load-env; hide-env WINPATH }
    closure => { with-env $in $exec }
  }
}

# Use or navigate to the Window's environment's `$env.USERPROFILE`.
@category filesystem
export def --env "win home" [
  --cd # Navigate to the resolved directory, if it exists
  --join (-j): list<string> = []
  # Path segments to join to the resolved home directory
  --edit (-e)
  # Open the resolved path with `$env.EDITOR`
  --posix (-p) = ($nu.os-info.name != windows)
  # Return the resolved path as a POSIX path
]: nothing -> oneof<nothing, directory> {
  let p: path = win env --vars=[$.USERPROFILE] | get $.USERPROFILE | path join ...$join
  if not $edit and not $cd {
    return ($p | if $posix { path as-posix } else { path as-windows })
  } else if $edit {
    run-external $env.EDITOR? $p
  } else if $cd {
    try { cd $p } catch { error make --unspanned $"resolved path is not a valid directory: '($p)'" }
  }
}

# Construct a windows path from the input path
@category filesystem
export def --env "win path" [
  --join (-j): list<string> = []
  # Path segments to join to the base path
  --cd (-c)
  # Set the working directory to the windows path
  --user (-u)
  # Use the user's home directory as the base path
  --edit (-e)
  # Open the resolved path with `$env.EDITOR`
  --posix (-p) = ($nu.os-info.name != windows)
  # Return the resolved path as a POSIX path
]: oneof<path, nothing> -> oneof<path, nothing> {
  let p: path = if $user { win home } else { '/mnt/c' } | path join ...$join
  if not $edit and not $cd {
    return ($p | if $posix { path as-posix } else { path as-windows })
  } else if $edit {
    run-external $env.EDITOR? $p
  } else if $cd {
    try { cd $p } catch { error make --unspanned $"resolved path is not a valid directory: '($p)'" }
  }
}
