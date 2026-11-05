# /work/dev/nu/reload/mod.nu

# Replace the current shell instance with a fresh one.
#
# Optionally, a record can be piped in which will be merged into
# the process environment.
@category shells
export def --env --wrapped main [
  --binary (-b): path = $nu.current-exe # Execute this file instead of `$nu.current-exe`
  --erase (-e) # Erase the history (clear without keeping scrollback)
  ...rest: string # Additional arguments for the Nushell invocation
]: oneof<nothing, record> -> nothing {
  default {} | with-env $in {
    match $nu.os-info.name { linux if $erase => { reset -wc } linux => { reset -w } }
    if $nu.is-interactive { hide-env --ignore-errors pid }
    if $nu.is-login { exec $binary --login ...$rest } else { exec $binary ...$rest }
  }
}
