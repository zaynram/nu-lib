# Link binaries found on PATH into the system-wide bin directory.

# ——— imports ——————————————————————————————————————————————————————————————————

use completion "into completions"
use error

# ——— definitions ——————————————————————————————————————————————————————————————

# Link a binary to the user bin directory.
#
# The link is `/usr/bin/<name>` on Linux (created with `sudo ln -s`) and `%USERPROFILE%\.local\bin\<name>` on
# Windows (created with `cmd /c mklink`). Its source is the first external `<name>` on PATH outside the link
# directory (on Linux, outside `/bin` and `/usr/bin`). A link that already resolves is returned unchanged, a
# dangling link is removed first, and any other existing file at the link path is an error. Errors carry the
# codes `link::bin::<kind>`.
@category platform
export def bin [
  name: oneof<string, path>@_executables # The name of the binary to link
]: nothing -> path {
  let os: string = $nu.os-info.name
  let config: record<link: path, skip: list<path>> = match $os {
    linux => {link: ('/usr/bin' | path join $name) skip: [/bin /usr/bin]}
    windows => {
      let dir: path = $env.USERPROFILE | path join .local bin
      {link: ($dir | path join $name) skip: [$dir]}
    }
    _ => { error raise --code=link::bin::unsupported_os $"unsupported operating system: '($os)'" }
  }
  match ($config.link | path type) {
    null => { }
    symlink if ($config.link | path exists) => { return $config.link }
    symlink => {
      match $os {
        windows => { rm $config.link }
        _ => { ^sudo unlink $config.link out+err>| complete | check 'unable to remove the dangling link' dangling_symlink }
      }
    }
    $type => { error raise --code=link::bin::link_exists $"a ($type) that is not a link already exists at '($config.link)'" }
  }
  let source: path = which --all $name
    | where type == external and ($it.path | path dirname) not-in $config.skip
    | get --optional 0.path
    | default {
      error raise --code=link::bin::source_not_found $"no external '($name)' found on PATH outside ($config.skip | str join ', ')"
    }
  match $os {
    windows => {
      mkdir ($config.link | path dirname)
      ^cmd /c mklink $config.link $source out+err>| complete
    }
    _ => { ^sudo ln -s $source $config.link out+err>| complete }
  } | check 'unable to link binary' non_zero_exit_code
  $config.link
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Raise `link::bin::<kind>` with the command output as advice when an external command failed.
def check [msg: string, kind: string]: record<stdout: string, exit_code: int> -> nothing {
  let result: record = $in
  if $result.exit_code == 0 { return }
  let output: string = $result.stdout | str trim
  error raise --code=$"link::bin::($kind)" $msg --advice=(if $output != '' { $"[output]\n($output)" }) | ignore
}

# ——— completions ——————————————————————————————————————————————————————————————

def _executables []: [nothing -> record] {
  which
  | where type == external
  | get command
  | path parse
  | get stem
  | into completions
}
