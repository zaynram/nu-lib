# Example: a personal `mount termux` for a phone running Termux (sshfs over the local network).
#
# A device's user, address, identity file and ssh port are machine configuration, so no such command lives in the
# library. Define a wrapper like this one in your own configuration — an autoload file in
# `($nu.default-config-dir)/autoload/` named to sort after `nu-lib.nu`, so that `mount` already resolves to the
# library's command — and edit the values. The record is what `mount --remote` takes; `mount` does nothing when the
# target is already a mount point, raises `mount::external_failure` with sshfs's message when the mount fails, and
# `mount unmount --remote` removes it again.

use mount

# Mount the phone's shared storage (`/storage/emulated/0`) at `/mnt/termux/`, or at the given path.
def "mount termux" [
  target: path = /mnt/termux/ # Where to mount the phone
]: nothing -> oneof<nothing, record> {
  mount $target --remote {user: u0_a123 ipv4: '192.168.1.23' auth: ('~/.ssh/termux' | path expand) port: 8022}
}
