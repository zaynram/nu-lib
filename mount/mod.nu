# Create and remove filesystem mounts: an sshfs mount of a remote device (e.g. one running Termux) or a bind mount.

# ——— imports ——————————————————————————————————————————————————————————————————

use error

# ——— helpers ——————————————————————————————————————————————————————————————————

def format-remote-options []: record<user: string, ipv4: string, auth: path> -> list<string> {
  return [
    $"IdentityFile=($in.auth),reconnect,ServerAliveInterval=15,idmap=user,uid=(id -u),gid=(id -g),StrictHostKeyChecking=accept-new"
    $"($in.user)@($in.ipv4):/storage/emulated/0"
  ]
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Check whether a path is a mount point (`mountpoint -q`, or `findmnt` when `mountpoint` is not installed).
export def is-mounted []: path -> bool {
  let target: path = $in | path expand
  if not ($target | path exists) { return false }
  if (which mountpoint | is-not-empty) {
    (^mountpoint -q $target | complete).exit_code == 0
  } else if (which findmnt | is-not-empty) {
    (^findmnt --noheadings --mountpoint $target | complete).exit_code == 0
  } else {
    error raise 'cannot check mount points: neither `mountpoint` nor `findmnt` is installed' --kind missing_dependency --advice 'install util-linux'
  }
}

# Unmount a filesystem, if the path is a mount point.
#
# A bind mount is removed with `umount` (which needs root); an sshfs mount (`--remote`) with `fusermount3 -u`.
export def unmount [--remote]: path -> nothing {
  let target: path = $in
  if not ($target | is-mounted) { return } else if $remote { ^fusermount3 -u $target } else { ^umount $target }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Create a filesystem mount from a remote device over sshfs, or bind-mount a local path.
#
# Nothing happens when `mount` is already a mount point. A remote record (piped or `--remote`) mounts the
# device's `/storage/emulated/0` with `sshfs`; otherwise `--source` is bind-mounted with `mount --mkdir --bind`,
# which requires running as root. Returns the `ls --directory` record of the mount.
@category filesystem
export def main [
  mount: path
  # The path of the mount to create
  --source (-s): path
  # The path of the item to mount
  --remote (-r): record<user: string, ipv4: string, auth: path, port: int>
  # The username, ipv4 address, identity file and ssh port of a remote device to mount from
]: oneof<nothing, record<user: string, ipv4: string, auth: path, port: int>> -> oneof<nothing, record> {
  let target: oneof<nothing, path, record> = default $remote | default $source
  let remote: bool = ($target | describe) starts-with record
  let program: string = if $remote { 'sshfs' } else { 'mount' }
  let result: record = match $target {
    _ if ($mount | is-mounted) => { return }
    {port: $p} => (^sshfs -p $p $mount -o ...($target | format-remote-options) | complete)
    $x if ($x | is-empty) => {
      error raise 'no source or remote configuration was provided' --kind invalid_argument --advice 'pass --source for a bind mount, or --remote (or pipe the record) for an sshfs mount'
    }
    _ if not (is-admin) => { error raise 'a bind mount needs root privileges' --kind unsupported --advice 'rerun with `sudo`' }
    $s => (^mount --mkdir --bind $s $mount | complete)
  }
  if $result.exit_code != 0 {
    try { $mount | unmount --remote=$remote } catch { ignore }
    error raise $"($program) exited with code ($result.exit_code)" --kind external_failure --advice (
      [$result.stderr? $result.stdout?] | compact | str trim | compact --empty | get --optional 0 | default (
        if $remote { 'ensure `sshd` is running on the remote host' }
      )
    )
  }
  ls --directory $mount | into record
}

# Mount a Termux phone (by default at `/mnt/termux/`) from the remote described by `$env.TERMUX_REMOTE`.
#
# The remote record `{user ipv4 auth port}` is machine configuration and lives in the environment (set it in your
# config or machine override), not in the library.
export def termux [
  mount: path = /mnt/termux/ # Where to mount the phone
]: nothing -> oneof<nothing, record> {
  let remote: record = $env.TERMUX_REMOTE?
    | default { error raise 'TERMUX_REMOTE is not set' --kind missing_dependency --advice 'set $env.TERMUX_REMOTE to {user: <user>, ipv4: <address>, auth: <identity file>, port: <ssh port>}' }
  main $mount --remote $remote
}
