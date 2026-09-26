# Utility module for creating/removing a filesystem mount from a host device running Termux.

# ——— helpers ——————————————————————————————————————————————————————————————————

def format-remote-options []: record<user: string, ipv4: string, auth: path> -> list<string> {
  return [
    $"IdentityFile=($in.auth),reconnect,ServerAliveInterval=15,idmap=user,uid=(id -u),gid=(id -g),StrictHostKeyChecking=accept-new"
    $"($in.user)@($in.ipv4):/storage/emulated/0"
  ]
}

# ——— aliases ——————————————————————————————————————————————————————————————————

# Check whether a named filesystem is currently mounted.
export def is-mounted []: path -> bool { try { ls --all $in | is-not-empty } catch { false } }
# Unmount the mounted filesystem, if it is mounted.
export def unmount [--remote]: path -> nothing {
  if not ($in | is-mounted) { return } else if $remote { fusermount3 -u $in } else { ^unmount $in }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Create or remove a filesystem mount for a configured device running Termux.
@category filesystem
export def mount [
  mount: path
  # The path of the mount to create
  --source (-s): path
  # The path of the item to mount
  --remote (-r): record<user: string, ipv4: string, auth: path, port: int>
  # The username, ipv4 address, and identity file to mount from a remote device
]: oneof<nothing, record<user: string, ipv4: string, auth: path, port: int>> -> oneof<nothing, record> {
  let target: oneof<nothing, path, record> = default $remote | default $source
  match $target {
    _ if ($mount | is-mounted) => { return }
    {port: $p} => {|| ^sshfs -p $p $mount -o ...($target | format-remote-options) }
    $x if ($x | is-empty) => { error make --unspanned 'no source or remote configuration was provided' }
    _ if not (is-admin) => { error make --unspanned 'missing required permissions; rerun with `sudo`' }
    $s => {|| ^sudo mount --mkdir --bind $s $mount }
  } | do --capture-errors $in
  | complete
  | if $in.exit_code != 0 {
    try { $mount | unmount } catch { ignore }
    error make --unspanned {
      msg: $"sshfs exited with code ($in.exit_code)"
      code: `filesystem::mount::external_non_zero_exit_code`
      help: ($in.stdout? | default --empty 'ensure `sshd` is running on the termux host')
    }
  } else {
    ls --directory $mount | into record
  }
}

export alias mount-termux = mount /mnt/termux/ --remote={
  user: u0_a530
  ipv4: 100.97.157.38
  auth: ~/.ssh/id_ed25519
  port: 8022
}
