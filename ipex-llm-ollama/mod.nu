# Commands for the IPEX-based Ollama installation providing GPU-accelerated inference in WSL.

const NAME: string = 'ipex-llm-ollama'
const HOME: path = $nu.home-dir | path join $'.($NAME)'
const SYCL: path = $HOME | path join ls-sycl-device
export-env {
  if ($HOME | path type) == dir and $env not-has IPEX_LLM_OLLAMA_HOME {
    $env.IPEX_LLM_OLLAMA_HOME = $HOME
    $env.PATH ++= [$HOME]
  }
}
# List the detected SYCL devices.
export alias device = run-external $SYCL

# Show the `systemctl` status for the Ollama service.
export def status []: nothing -> record<state: string, spawned: oneof<datetime, string>> {
  systemctl status ipex-llm-ollama --no-pager --lines 0 out+err>|
  | find 'Active: ' --no-highlight
  | str trim --left
  | parse 'Active: {state} since {spawned}; {_}'
  | into record
  | update spawned {|row| try { into datetime } catch { $row.spawned } }
}

# Start the IPEX-LLM Ollama server.
export def serve []: nothing -> record {
  let desc: string = $'($NAME)_serve'
  job spawn --description=$desc { cd $HOME; bash start-ollama.sh out+err>| job send 0 }
  print 'server started; run `job recv` to stream output'
  job list | where description == $desc | first
}
