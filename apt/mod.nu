# Apt-related shorthand and utility methods.

# nu-lint-ignore-file: unhandled_external_error, pipe_spacing

# Auto-elevating apt wrapper
export alias sap = sudo apt-get
# Install a system package using apt.
export alias agi = sudo apt-get install --yes
# Update and upgrade the system packages.
export alias agu = try {
  sudo apt-get update --yes
  sudo apt-get upgrade --yes
}
# Run the automated cleanup scripts for apt
export alias acl = try {
  sudo apt-get autoremove --yes
  sudo apt-get autoclean --yes
}
# Run the automated cleanup scripts for apt, optionally uninstalling packages first.
export def arm [
  ...names: string@_removable-packages # Names of any packages to remove
]: nothing -> nothing {
  try {
    if ($names | is-not-empty) { sudo apt-get remove --yes ...$names }
    sudo apt-get autoremove --yes
    sudo apt-get autoclean --yes
  }
}

# ——— completions ————————————————————————————————————————————————————————————

def _removable-packages [context: string]: nothing -> list {
  $context
  | split row (char space)
  | skip
  | prepend [sudo apt-get remove]
  | str join (char space)
  | collect { commandline complete }
}
