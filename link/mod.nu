# /work/dev/nu/link/mod.nu

# ——— imports ——————————————————————————————————————————————————————————————————

use completion "into completions"

# ——— definitions ——————————————————————————————————————————————————————————————

# Link a binary to the user bin directory.
@category platform
export def bin [
  name: oneof<string, path>@_executables # The name of the binary to link
]: nothing -> path {
  let config: record<link: path, regex: string> = match $nu.os-info.name {
    linux => {
      link: $"/usr/bin/($name)"
      regex: $"^/\(bin|usr/bin)/($name)$"
    }
    windows => {
      let lnk: path = $env.USERPROFILE | path join .local bin $name
      return {link: $lnk regex: $lnk}
    }
  }
  match ($config.link | path type) {
    symlink if ($config.link | path exists) => { return $config.link }
    symlink => {
      sudo unlink $config.link out+err>| complete
      | if $in.exit_code? != 0 { error 'unable to remove link' bin-link dangling_symlink }
    }
  }
  which --all $name
  | where path !~ $config.regex
  | get --optional 0.path
  | if $in == null { error "unable to detect source binary" } else {
    let path: path = $in
    match $nu.os-info.name {
      linux => { sudo ln -s $path $config.link out+err>| complete }
      windows => { mklink $config.link $path out+err>| complete }
    } | if $in.exit_code? != 0 {
      error 'unable to link binary' bin-link non_zero_exit_code
    } else {
      return $config.link
    }
  }
}
# ——— helpers —————————————————————————————————————————————————————————————————

def error [msg: string ...code: string]: oneof<nothing, record<stdout: string>> -> error {
  let details: record = match $in {
    {stdout: $s} | {stderr: $s} => $"[output]\n($s)"
    $s if ($s | describe) == string => $s
    null => ''
  } | wrap help
    | insert msg $msg
    | insert code {
      $code
      | default --empty [internal_error]
      | prepend [internal util]
      | str join ::
    }
    | compact --empty
  error make --unspanned $details
}

# ——— completions —————————————————————————————————————————————————————————————

def _executables []: [nothing -> record] {
  which
  | where type == external
  | get command
  | path parse
  | get stem
  | into completions
}
