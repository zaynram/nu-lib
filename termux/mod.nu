# Utility module for creating/removing a filesystem mount from a host device running Termux.

# ——— constants ————————————————————————————————————————————————————————————————

const _mnt: record<name: string, path: path, ipv4: string, auth: path> = {
  name: u0_a530
  path: /mnt/termux/
  ipv4: 100.97.157.38
  auth: ~/.ssh/id_ed25519
}

# ——— aliases ——————————————————————————————————————————————————————————————————

# Check whether the Termux filesystem is currently mounted.
export alias is-mounted = do --ignore-errors { glob $"($_mnt.path)/*" --depth=1 | is-not-empty }
# Unmount the Termux filesystem, if it is mounted.
export alias unmount = do --capture-errors {|p: path = $_mnt.path| if (is-mounted) { fusermount3 -u $p } }

# ——— definitions ——————————————————————————————————————————————————————————————

# Create or remove a filesystem mount for a configured device running Termux.
export def mount [
  --name (-n): string = $_mnt.name # The username of the termux login
  --path (-p): path = $_mnt.path # The path of the termux filesystem mount
  --ipv4 (-i): string = $_mnt.ipv4 # The IP address of the termux device
  --auth (-a): path = $_mnt.auth # The identity file to use for authentication
]: nothing -> oneof<nothing, table> {
  if (is-mounted) { return }
  ^sshfs -p 8022 $path -o ...[
    $"IdentityFile=($auth),reconnect,ServerAliveInterval=15,idmap=user,uid=(id -u),gid=(id -g),StrictHostKeyChecking=accept-new"
    $"($name)@($ipv4):/storage/emulated/0"
  ] out+err>|
  | complete
  | match $in.exit_code {
    0 => { ls --directory $path | return $in }
    $c => {
      try { unmount } catch { ignore }
      error make --unspanned {
        msg: $"sshfs exited with code ($c)"
        code: `termux::mnt::external_non_zero_exit_code`
        help: ($in.stdout? | default --empty 'ensure `sshd` is running on the termux host')
      }
    }
  }
}
