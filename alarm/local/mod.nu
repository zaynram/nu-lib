# Named alarms (see `alarm`) whose expiry opens a small `tui` popup with the alarm's text and a dismiss button.
#
# Configuration-dependent: the dialog needs the `tui` commands and an interactive terminal. Without them an
# expired alarm prints its text instead, and still runs its callback and forgets itself.

# ——— imports ——————————————————————————————————————————————————————————————————

# The abstract module: `unset`, `list` and `show` are re-exported unchanged; `main` and `set` are redefined below
# (a star re-export would also export its `main`, named after the file: `mod`).
export use ../mod.nu [ unset list show ]

# ——— constants ————————————————————————————————————————————————————————————————

const EMPTY: list<nothing> = []

# ——— definitions —————————————————————————————————————————————————————————————

# Set an alarm; returns its record `{id description expires_at on_expires}`.
#
# As `alarm set`, but the notification is a `tui` dialog that stays until dismissed; the alarm is forgotten
# once the dialog closes.
@category productivity
export def set [
  name: string@$EMPTY # Descriptor for this alarm
  when: oneof<duration, datetime, string>@_suggest-when # When the timer will expire
  --then (-t): closure # Closure to run once the timer expires; its output is printed unless `--silent`
  --silent (-s) # Expire quietly: no dialog, and the callback's output is discarded
]: nothing -> record {
  use ../mod.nu
  mod set $name $when --then=$then --silent=$silent --notify={|text: string| dialog $text }
}

# List the alarms, or show one by name.
@category productivity
export def main [
  name?: string # Name of the alarm to show
]: nothing -> oneof<nothing, record, table> {
  use ../mod.nu
  mod $name
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Show the alarm's text in a small (60x5) `tui` popup until it is dismissed; print it when the dialog cannot open.
# nu-lint-ignore: unused_helper_functions
def dialog [text: string]: nothing -> nothing {
  if (which tui | is-empty) { print $text; return }
  try {
    tui label --status $text | tui button 'dismiss' {|| {action: quit} } | tui run --dialog --size [60 5]
  } catch {
    print $text
  }
  null
}

# ——— completions —————————————————————————————————————————————————————————————

def _suggest-when []: nothing -> list {
  let now = date now
  [1min 5min 10min 15min 20min 30min 1hr 1.5hr 2hr]
  | each { $now + $in | date humanize | $"'($in)'" }
}
