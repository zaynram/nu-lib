# Replace the current shell with a fresh `nu` process.

# Replace the current shell instance with a fresh one.
#
# Optionally, a record can be piped in which will be merged into the process environment. On Linux, when stdin is
# a terminal, the terminal is reset first (`reset -w`, or `reset -wc` with `--erase`); without a terminal (scripts,
# pipes) the reset is skipped. An interactive shell drops `$env.pid` first: `exec` keeps the process id, so an
# inherited `pid` would make the new shell's config take itself for already loaded.
@category shells
export def --env --wrapped main [
  --binary (-b): path = $nu.current-exe # Execute this file instead of `$nu.current-exe`
  --erase (-e) # Also restore the terminal's control characters and modes (`reset -wc`, like a plain `reset`)
  ...rest: string # Additional arguments for the Nushell invocation
]: oneof<nothing, record> -> nothing {
  default {} | with-env $in {
    if $nu.os-info.name == linux and (is-terminal --stdin) { if $erase { ^reset -wc } else { ^reset -w } }
    if $nu.is-interactive { hide-env --ignore-errors pid }
    if $nu.is-login { exec $binary --login ...$rest } else { exec $binary ...$rest }
  }
}
