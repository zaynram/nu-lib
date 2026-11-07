# `link bin` with a stub `sudo` on PATH: `test _tests/suites/link.nu`.
#
# The link path is fixed (`/usr/bin/<name>` on Linux), so cases use names that do not exist there and a stub
# `sudo` that only records its arguments: nothing is ever linked or unlinked for real.
use link
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path name: path body: string]: nothing -> path {
  need-posix
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

# Run `body` with a recording stub `sudo` (exit code `code`, printing `output`) first on PATH.
#
# The closure receives {ctx, bin, log}: `bin` is a PATH directory for source binaries, `log` the file that
# collects one line of arguments per `sudo` call.
def with-stub-sudo [body: closure --code: int = 0 --output: string = '']: nothing -> nothing {
  if $nu.os-info.name != linux { skip 'the link path is Linux-specific' }
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    let bin: path = $ctx.code | path join bin
    let log: path = $ctx.code | path join sudo.log
    mkdir $stubs $bin
    stub $stubs sudo $"printf '%s\\n' \"$*\" >> '($log)'\nprintf '%s' '($output)'\nexit ($code)" | ignore
    with-env {PATH: ($env.PATH | prepend [$stubs $bin])} {
      assert equal (which sudo | get $.0.path) ($stubs | path join sudo) 'the stub sudo shadows the real one'
      do $body {ctx: $ctx bin: $bin log: $log}
    }
  } | ignore
}

def sudo-calls [log: path]: nothing -> list<string> {
  if ($log | path exists) { open $log | lines } else { [] }
}

# A fresh name with nothing at `/usr/bin/<name>`.
def unused-name []: nothing -> string {
  let name: string = $"nulib-link-test-(random chars --length 8 | str lowercase)"
  if ('/usr/bin' | path join $name | path type) != null { skip $"/usr/bin/($name) exists" }
  $name
}

# ——— cases ————————————————————————————————————————————————————————————————————

def "test the name is a string" []: nothing -> nothing {
  let shape = scope commands | where name == 'link bin' | get $.0.signatures | values | flatten | where parameter_name == name | get $.0.syntax_shape
  assert equal $shape string 'a path never links: the source is looked up on PATH by name'
}

def "test links the first external on PATH into usr bin" []: nothing -> nothing {
  with-stub-sudo {|t|
    let name: string = unused-name
    let first: path = stub $t.bin $name 'exit 0'
    let other: path = $t.ctx.code | path join other
    mkdir $other
    stub $other $name 'exit 0' | ignore
    let link: path = with-env {PATH: ($env.PATH | append $other)} { link bin $name }
    assert equal $link $"/usr/bin/($name)" 'returns the link path'
    assert equal (sudo-calls $t.log) [$"ln -s ($first) /usr/bin/($name)"] 'links the first match on PATH'
  }
}

def "test an existing resolving link is returned unchanged" []: nothing -> nothing {
  with-stub-sudo {|t|
    let found: list<string> = ls /usr/bin | where type == symlink and ($it.name | path exists) | get $.name
    if ($found | is-empty) { skip 'no resolving symlink in /usr/bin' }
    let name: string = $found | first | path basename
    assert equal (link bin $name) $"/usr/bin/($name)" 'returns the existing link'
    assert equal (sudo-calls $t.log) [] 'sudo is not called'
  }
}

def "test a dangling link is removed before linking" []: nothing -> nothing {
  with-stub-sudo {|t|
    let found: list<string> = ls /usr/bin | where type == symlink and not ($it.name | path exists) | get $.name
    if ($found | is-empty) { skip 'no dangling symlink in /usr/bin' }
    let name: string = $found | first | path basename
    let source: path = stub $t.bin $name 'exit 0'
    assert equal (link bin $name) $"/usr/bin/($name)" 'returns the link path'
    assert equal (sudo-calls $t.log) [$"unlink /usr/bin/($name)" $"ln -s ($source) /usr/bin/($name)"] 'unlinks, then links'
  }
}

def "test a regular file at the link path is an error" []: nothing -> nothing {
  with-stub-sudo {|t|
    let found: list<string> = ls /usr/bin | where type == file and ($it.name | path basename) =~ '^[a-z][a-z0-9_-]+$' | get $.name
    if ($found | is-empty) { skip 'no regular file in /usr/bin' }
    let name: string = $found | first | path basename
    stub $t.bin $name 'exit 0' | ignore
    let err = try { link bin $name; null } catch {|e| $e.details }
    assert equal $err.code? link::bin::conflict 'a non-link at the link path is a conflict'
    assert str contains $err.msg $"/usr/bin/($name)" 'names the link path'
    assert equal (sudo-calls $t.log) [] 'sudo is not called'
  }
}

def "test a missing source binary is an error" []: nothing -> nothing {
  with-stub-sudo {|t|
    let err = try { link bin (unused-name); null } catch {|e| $e.details }
    assert equal $err.code? link::bin::not_found 'no source is not_found'
    assert equal (sudo-calls $t.log) [] 'sudo is not called'
  }
}

def "test builtins are not link sources" []: nothing -> nothing {
  with-stub-sudo {|t|
    if ('/usr/bin/str' | path type) != null { skip '/usr/bin/str exists' }
    assert ((which --all str | where type != external) | is-not-empty) 'str is a builtin'
    let err = try { link bin str; null } catch {|e| $e.details }
    assert equal $err.code? link::bin::not_found 'a builtin has no binary to link'
    assert equal (sudo-calls $t.log) [] 'sudo is not called'
  }
}

def "test a failed link raises with the command output" []: nothing -> nothing {
  with-stub-sudo --code=1 --output='ln: permission denied' {|t|
    let name: string = unused-name
    stub $t.bin $name 'exit 0' | ignore
    let err = try { link bin $name; null } catch {|e| $e.details }
    assert equal $err.code? link::bin::external_failure 'a failed ln is an external failure'
    assert ($err.msg =~ $"^unable to link '.*/($name)' at '/usr/bin/($name)'$") $'the message names the source and the link: ($err.msg)'
    assert str contains $err.help 'ln: permission denied' 'the command output is the advice'
  }
}

def "test the windows link lives in the user bin directory" []: nothing -> nothing {
  if $nu.os-info.name != windows { skip 'Windows only' }
  let name: string = $"nulib-link-test-(random chars --length 8 | str lowercase)"
  let err = try { link bin $name; null } catch {|e| $e.details }
  assert equal $err.code? link::bin::not_found 'nothing to link'
}
