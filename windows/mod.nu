# Utilities and optimization methods for clean separation of the Windows host environment when working in the WSL Debian environment.

# nu-lint-ignore-file: missing_output_type

# ——— imports ——————————————————————————————————————————————————————————————————

use error

# ——— constants ————————————————————————————————————————————————————————————————

const _save: path = $nu.data-dir | path join windows_env.msgpack
# Where Windows executables are expected when neither PATH nor WINPATH has them.
const SYSTEM32: path = '/mnt/c/Windows/System32'

# ——— aliases ——————————————————————————————————————————————————————————————————

# Run the PowerShell 7 executable.
export alias pwsh = /mnt/c/progra~1/PowerShell/7/pwsh.exe
# Run a command with PowerShell 7 (use `pwsh` directly to choose another execution policy).
export alias "pwsh x" = pwsh -nop -noni -ExecutionPolicy Bypass -c
# Run the Windows PowerShell (5.1) executable.
export alias powershell = /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
# Run a command with Windows PowerShell (use `powershell` directly to choose another execution policy).
export alias "powershell x" = powershell -nop -noni -ExecutionPolicy Bypass -c
# Convert Windows path(s) to POSIX path(s) with `wslpath -u`; POSIX paths pass through unchanged.
#
# A path `wslpath` cannot convert becomes null, and is dropped from a list.
export alias "path as-posix" = each {|| if $in starts-with / { } else { try { ^wslpath -u $in } } }
# Convert POSIX path(s) to Windows path(s) with `wslpath -m` (forward slashes).
#
# A path `wslpath` cannot convert becomes null, and is dropped from a list.
export alias "path as-windows" = each {|| try { ^wslpath -m $in } }

# ——— helpers ——————————————————————————————————————————————————————————————————

# The path of a Windows executable: the first match on PATH or WINPATH, else `fallback`.
def win-exe [name: string, fallback: path]: nothing -> path {
  with-env {PATH: ($env.PATH | append ($env.WINPATH? | default [] | split row (char esep)))} { which --all $name }
  | where type == external
  | get --optional 0.path
  | default $fallback
}

# The Windows PATH as reported by Windows PowerShell, as POSIX paths (entries with unexpanded `%VARS%` dropped).
def powershell-path []: nothing -> list<path> {
  let exe: path = win-exe powershell.exe ($SYSTEM32 | path join WindowsPowerShell v1.0 powershell.exe)
  ^$exe -nop -noni -ExecutionPolicy Bypass -c '$env:PATH'
  | split row ';'
  | str trim
  | where $it != '' and $it !~ '%\w+%'
  | path as-posix
  | compact
}

# ——— environment ——————————————————————————————————————————————————————————————

# Unless WINPATH exists, move the PATH entries under a Windows drive mount (`/mnt/<letter>/…`) to WINPATH; set
# WSL_DISTRO_NAME to the first word of the OS name (`sys host | get name`, e.g. `Debian`) when it is missing.
export-env {
  if $env not-has WINPATH {
    $env.PATH
    | split row (char esep)
    | flatten
    | uniq
    | group-by {|p| if $p =~ '^/mnt/[[:alpha:]]/' { 'WINPATH' } else { 'PATH' } }
    | default [] PATH
    | default [] WINPATH
    | load-env
  }
  if $env not-has WSL_DISTRO_NAME { $env.WSL_DISTRO_NAME = sys host | get name | split words | first }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Run a command on the Windows PATH, if it exists.
@category platform
export def --wrapped "win run" [
  name: string
  # The name of the application to run
  ...rest: string
  # Arguments to pass through to the application if it resolves
]: nothing -> any {
  win which $name | match ($in | describe) {
    string => { run-external $in ...$rest }
    nothing => { error raise $"command not found: '($name)'" --kind not_found }
    $t => { error raise $"unexpected return type of `win which`: '($t)'" --kind internal }
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
  let where_exe: path = win-exe where.exe ($SYSTEM32 | path join where.exe)
  let where: closure = {|a: string|
    ^$where_exe $a | complete
    | if $in.exit_code == 0 { $in.stdout | lines | str trim --right | where $it != '' } else { [] }
    | path as-posix
    | if $all { } else { get --optional 0 }
  }
  match ($names | length) {
    0 => { return }
    1 => { do $where $names.0 } # nu-lint-ignore: unchecked_cell_path_index
    _ => { $names | each {|n| {$n: (do $where $n)} } | into record }
  }
}

# Utilize the full Windows environment for a single command or load it into the session.
#
# The Windows variables are PATH (WINPATH, else what Windows PowerShell reports), USERPROFILE (else
# `/mnt/c/Users/$USER`, assuming the Windows user name matches) and PATHEXT. They are cached in
# `$nu.data-dir/windows_env.msgpack` until `--reset`; `--path` applies to every call, cached or not. A piped
# record is deep-merged in, its lists first.
@category env
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
  let input: record = default {}
  if $path not-in [merge overwrite] {
    error raise $"invalid value for `--path`: '($path)'" --kind invalid_argument --advice 'merge or overwrite'
  }
  # the cache holds the raw Windows variables; `--path` is applied afterwards
  let windows: record = if $reset { null } else { try { open $_save | from msgpack } }
    | default --empty {
      let e: record = {
        PATH: ($env.WINPATH? | default [] | split row (char esep) | default --empty { powershell-path })
        USERPROFILE: ($env.USERPROFILE? | default --empty $"/mnt/c/Users/($env.USER)")
        PATHEXT: ($env.PATHEXT? | default --empty '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.CPL')
      }
      $e | to msgpack | save --force $_save
      $e
    }
  let windows_path: list<string> = if $path == merge { $env.PATH | append $windows.PATH } else { $windows.PATH }
  $windows
  | merge {PATH: ($windows_path | uniq)}
  | merge deep --strategy=prepend $input
  | select --optional ...$vars
  | compact
  | match ($exec | describe) {
    nothing if not $load => { }
    nothing => { load-env; hide-env --ignore-errors WINPATH }
    closure => { with-env $in $exec }
  }
}

# Use or navigate to the Windows environment's `$env.USERPROFILE` (see `win env`).
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
    try { cd $p } catch {|e| $e | error raise $"resolved path is not a valid directory: '($p)'" --kind not_found }
  }
}

# Construct a path under a base: the piped path, else the Windows system drive (`/mnt/c`), or the Windows home
# directory with `--user` (which applies only without input).
@category filesystem
export def --env "win path" [
  --join (-j): list<string> = []
  # Path segments to join to the base path
  --cd (-c)
  # Set the working directory to the windows path
  --user (-u)
  # Use the user's home directory as the base path (when no path is piped)
  --edit (-e)
  # Open the resolved path with `$env.EDITOR`
  --posix (-p) = ($nu.os-info.name != windows)
  # Return the resolved path as a POSIX path
]: oneof<path, nothing> -> oneof<path, nothing> {
  let base: oneof<path, nothing> = $in
  let p: path = if $base != null { $base } else if $user { win home } else { '/mnt/c' } | path join ...$join
  if not $edit and not $cd {
    return ($p | if $posix { path as-posix } else { path as-windows })
  } else if $edit {
    run-external $env.EDITOR? $p
  } else if $cd {
    try { cd $p } catch {|e| $e | error raise $"resolved path is not a valid directory: '($p)'" --kind not_found }
  }
}
