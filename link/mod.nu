# Link binaries found on PATH into the bin directory (`/usr/bin` on Linux, `%USERPROFILE%\.local\bin` on Windows).

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
# codes `link::bin::<kind>`: `unsupported` (the OS), `conflict` (a non-link at the link path), `not_found` (no
# source on PATH) and `external_failure` (`unlink`/`ln`/`mklink` failed; what they printed is the advice).
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
    _ => { error raise $"unsupported operating system: '($os)'" --kind unsupported }
  }
  match ($config.link | path type) {
    null => { }
    symlink if ($config.link | path exists) => { return $config.link }
    symlink => {
      match $os {
        windows => { rm $config.link }
        _ => {
          let res: record = ^sudo unlink $config.link out+err>| complete
          if $res.exit_code != 0 {
            error raise $"unable to remove the dangling link '($config.link)'" --kind external_failure --advice ($res.stdout | str trim)
          }
        }
      }
    }
    $type => { error raise $"a ($type) that is not a link already exists at '($config.link)'" --kind conflict }
  }
  let source: path = which --all $name
    | where type == external and ($it.path | path dirname) not-in $config.skip
    | get --optional 0.path
    | default {
      error raise $"no external '($name)' found on PATH outside ($config.skip | str join ', ')" --kind not_found
    }
  let res: record = match $os {
    windows => {
      mkdir ($config.link | path dirname)
      ^cmd /c mklink $config.link $source out+err>| complete
    }
    _ => { ^sudo ln -s $source $config.link out+err>| complete }
  }
  if $res.exit_code != 0 {
    error raise $"unable to link '($source)' at '($config.link)'" --kind external_failure --advice ($res.stdout | str trim)
  }
  $config.link
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
