# `mount` with stub `sshfs`, `mount`, `umount`, `fusermount3` and `mountpoint`: `test _tests/suites/mount.nu`.
#
# Only `mountpoint`/`findmnt` ever run for real (read-only checks). Mounting and unmounting always go through
# stubs that log their arguments, asserted first on PATH; a stub `mountpoint` fakes an existing mount.
use mount
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path, name: path, body: string]: nothing -> path {
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

const REMOTE: record = {user: u0_a1 ipv4: 10.0.0.2 auth: /keys/id port: 8022}

# Run `body` with logging stubs of the mount programs first on PATH (`--mounted` adds a `mountpoint` stub that
# reports every path as mounted; `--sshfs` sets the stub sshfs's body). The closure receives {ctx, dir, log}:
# `dir` is an empty directory to mount on.
def with-stubs [body: closure, --mounted, --sshfs: string = 'exit 0']: nothing -> nothing {
  if $nu.os-info.name != linux { skip 'mount points are checked with Linux tools' }
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    let log: path = $ctx.code | path join calls.log
    let dir: path = $ctx.code | path join mnt
    mkdir $stubs $dir
    [umount fusermount3 mount] | each {|p| stub $stubs $p $"echo \"($p) $*\" >> '($log)'" } | ignore
    stub $stubs sshfs $"echo \"sshfs $*\" >> '($log)'\n($sshfs)" | ignore
    if $mounted { stub $stubs mountpoint 'exit 0' | ignore }
    with-env {PATH: ($env.PATH | prepend $stubs)} {
      for p in [umount fusermount3 mount sshfs] {
        let found: string = which --all $p | where type == external | get 0.path
        assert equal $found ($stubs | path join $p) $"the stub ($p) shadows the real one"
      }
      if (which mountpoint findmnt | is-empty) { skip 'neither mountpoint nor findmnt is installed' }
      do $body {ctx: $ctx dir: $dir log: $log}
    }
  } | ignore
}

def calls [log: path]: nothing -> list<string> {
  if ($log | path exists) { open $log | lines } else { [] }
}

# ——— is-mounted ———————————————————————————————————————————————————————————————

def "test is mounted recognises a mount point" []: nothing -> nothing {
  if (which mountpoint findmnt | is-empty) { skip 'neither mountpoint nor findmnt is installed' }
  assert ('/' | mount is-mounted) 'the root filesystem'
}

def "test is mounted is false for anything that is not a mount point" []: nothing -> nothing {
  if (which mountpoint findmnt | is-empty) { skip 'neither mountpoint nor findmnt is installed' }
  with-sandbox {|ctx|
    let empty: path = $ctx.code | path join empty
    let full: path = $ctx.code | path join full
    mkdir $empty $full
    touch ($full | path join f)
    assert not ($empty | mount is-mounted) 'an empty directory'
    assert not ($full | mount is-mounted) 'a populated directory'
    assert not ($full | path join f | mount is-mounted) 'a file'
    assert not ($ctx.code | path join missing | mount is-mounted) 'a missing path'
  } | ignore
}

def "test is mounted falls back to findmnt" []: nothing -> nothing {
  with-sandbox {|ctx|
    let log: path = $ctx.code | path join calls.log
    stub $ctx.code findmnt $"echo \"findmnt $*\" >> '($log)'" | ignore
    let result = with-env {PATH: [$ctx.code]} { $ctx.code | mount is-mounted }
    assert $result 'findmnt found it'
    assert equal (calls $log) [$"findmnt --noheadings --mountpoint ($ctx.code)"] 'asks findmnt for the mount point'
  } | ignore
}

def "test is mounted without mountpoint or findmnt is an error" []: nothing -> nothing {
  with-sandbox {|ctx|
    let err = try { with-env {PATH: [$ctx.code]} { $ctx.code | mount is-mounted }; null } catch {|e| $e.details }
    assert equal $err.code? mount::is-mounted::missing_dependency 'raises missing_dependency'
  } | ignore
}

# ——— unmount ——————————————————————————————————————————————————————————————————

def "test unmount does nothing without a mount" []: nothing -> nothing {
  with-stubs {|t|
    $t.dir | mount unmount
    $t.dir | mount unmount --remote
    assert equal (calls $t.log) [] 'nothing to unmount'
  }
}

def "test unmount removes a bind mount with umount" []: nothing -> nothing {
  with-stubs --mounted {|t|
    $t.dir | mount unmount
    assert equal (calls $t.log) [$"umount ($t.dir)"] 'umount, not unmount'
  }
}

def "test unmount removes a remote mount with fusermount3" []: nothing -> nothing {
  with-stubs --mounted {|t|
    $t.dir | mount unmount --remote
    assert equal (calls $t.log) [$"fusermount3 -u ($t.dir)"] 'fusermount3 -u'
  }
}

# ——— mount ————————————————————————————————————————————————————————————————————

def "test mount does nothing when already mounted" []: nothing -> nothing {
  with-stubs --mounted {|t|
    assert equal (mount $t.dir --remote $REMOTE) null 'returns nothing'
    assert equal (mount $t.dir --source /tmp) null 'also for a bind mount'
    assert equal (calls $t.log) [] 'nothing runs'
  }
}

def "test mount needs a source or a remote" []: nothing -> nothing {
  with-stubs {|t|
    let err = try { mount $t.dir; null } catch {|e| $e }
    assert equal $err.msg 'no source or remote configuration was provided' 'error message'
    assert equal $err.details?.code? mount::invalid_argument 'the code (main has no command segment)'
  }
}

def "test a bind mount requires root" []: nothing -> nothing {
  if (is-admin) { skip 'running as root' }
  with-stubs {|t|
    let err = try { mount $t.dir --source /tmp; null } catch {|e| $e }
    assert equal $err.msg 'a bind mount needs root privileges' 'error message'
    assert equal $err.details?.code? mount::unsupported 'the code'
    assert str contains ($err.details?.help? | default '') 'sudo' 'the remedy is the advice'
    assert equal (calls $t.log) [] 'mount is not run'
  }
}

def "test a bind mount as root runs mount bind" []: nothing -> nothing {
  if not (is-admin) { skip 'needs root (mount itself is a stub)' }
  with-stubs {|t|
    mount $t.dir --source /tmp | ignore
    assert equal (calls $t.log) [$"mount --mkdir --bind /tmp ($t.dir)"] 'mount --bind, without sudo'
  }
}

def "test a remote mount runs sshfs with the device options" []: nothing -> nothing {
  with-stubs {|t|
    let result = mount $t.dir --remote $REMOTE
    assert equal $result.name $t.dir 'returns the ls record of the mount'
    let options: string = [
      'IdentityFile=/keys/id,reconnect,ServerAliveInterval=15,idmap=user'
      $"uid=(^id -u | str trim),gid=(^id -g | str trim),StrictHostKeyChecking=accept-new"
    ] | str join ','
    let expected: string = $"sshfs -p 8022 ($t.dir) -o ($options) u0_a1@10.0.0.2:/storage/emulated/0"
    assert equal (calls $t.log) [$expected] 'sshfs arguments'
  }
}

def "test a piped remote record works like the flag" []: nothing -> nothing {
  with-stubs {|t|
    $REMOTE | mount $t.dir | ignore
    assert ((calls $t.log | first) starts-with 'sshfs -p 8022') 'sshfs runs'
  }
}

def "test a failed sshfs raises its error output" []: nothing -> nothing {
  with-stubs --sshfs="echo 'connection refused' >&2; exit 1" {|t|
    let err = try { mount $t.dir --remote $REMOTE; null } catch {|e| $e.details }
    assert equal $err.msg 'sshfs exited with code 1' 'names the program and exit code'
    assert equal $err.code? mount::external_failure 'error code'
    assert equal $err.help? 'connection refused' 'the stderr is the help'
  }
}

def "test a silent sshfs failure suggests checking sshd" []: nothing -> nothing {
  with-stubs --sshfs='exit 2' {|t|
    let err = try { mount $t.dir --remote $REMOTE; null } catch {|e| $e.details }
    assert str contains $err.help? 'sshd' 'a hint about the remote host'
  }
}

def "test termux mounts the configured phone" []: nothing -> nothing {
  let alias = scope aliases | where name == 'mount termux' | first
  assert str contains $alias.expansion '/mnt/termux/' 'mount point'
  assert str contains $alias.expansion 'port: 8022' 'remote device'
}
