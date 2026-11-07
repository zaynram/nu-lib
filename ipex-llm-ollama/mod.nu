# Commands for the IPEX-based Ollama installation providing GPU-accelerated inference in WSL.

# ——— imports ——————————————————————————————————————————————————————————————————

use error

# ——— helpers ——————————————————————————————————————————————————————————————————

def home []: nothing -> path {
  $env.IPEX_LLM_OLLAMA_HOME? | default --empty ($nu.data-dir | path dirname | path join ipex-llm-ollama)
}

# ——— definitions ——————————————————————————————————————————————————————————————

# List the detected SYCL devices.
export alias device = ^ls-sycl-device

# Show the `systemctl` status for the Ollama service.
#
# `state` is the `Active:` state (e.g. `active (running)`, `inactive (dead)`); `spawned` is when it entered that
# state (a datetime, or the raw text when it does not parse), or null when systemd reports no time.
@category system
export def status []: nothing -> record<state: string, spawned: oneof<datetime, string, nothing>> {
  # `systemctl status` exits non-zero for inactive units too, so the `Active:` line decides, not the exit code
  # nu-lint-ignore: check_complete_exit_code
  let result: record = ^systemctl status ipex-llm-ollama --no-pager --lines 0 out+err>| complete
  let active: list<string> = $result.stdout | lines | str trim | where $it starts-with 'Active: '
  if ($active | is-empty) {
    error raise $"no status reported by systemctl \(exit code ($result.exit_code)\)" --with={
      kind: external_failure
      help: ($result.stdout | str trim)
    }
  }
  $active
  | first
  | parse --regex '^Active: (?<state>.+?)(?: since (?<spawned>[^;]+)(?:;.*)?)?$'
  | first
  | update spawned {|row|
    if ($row.spawned | is-empty) { null } else { try { $row.spawned | into datetime } catch { $row.spawned } }
  }
}

# Start the IPEX-LLM Ollama server in a background job.
#
# Runs `bash start-ollama.sh` in the installation directory. Its combined output is sent to job 0 (`job recv`)
# as one message when the server exits. This runs a server of its own, independent of the systemd service that
# `status` reports on.
@category system
export def serve []: nothing -> record {
  let dir: path = home
  let id: int = job spawn --description='ipex-llm-ollama_serve' { cd $dir; ^bash start-ollama.sh out+err>| job send 0 }
  print $'server started; its output arrives with `job recv` when it exits'
  job list | where id == $id | get --optional 0 | default {id: $id description: 'ipex-llm-ollama_serve'}
}

# ——— environment ——————————————————————————————————————————————————————————————

# The installation directory is `$env.IPEX_LLM_OLLAMA_HOME`, by default `ipex-llm-ollama` next to the Nushell data
# directory (`~/.local/share/ipex-llm-ollama`); it is exported and appended to PATH (once).
export-env {
  $env.IPEX_LLM_OLLAMA_HOME = home
  use std/util "path add"
  path add --append $env.IPEX_LLM_OLLAMA_HOME
}
