# Commands for the IPEX-based Ollama installation providing GPU-accelerated inference in WSL.

export-env {
  let home: path = $env.IPEX_LLM_OLLAMA_HOME!? | default ($nu.home-dir | path join $'.ipex-llm-ollama')
  if $env.ipex_llm_ollama_home!? != $home {
    $env.ipex_llm_ollama_home! = $home
    use std/util "path add"
    path add --append $home
  }
}

# List the detected SYCL devices.
export alias device = run-external ls-sycl-device

# Show the `systemctl` status for the Ollama service.
@category system
export def status []: nothing -> record<state: string, spawned: oneof<datetime, string>> {
  systemctl status ipex-llm-ollama --no-pager --lines 0 out+err>|
  | find 'Active: ' --no-highlight
  | str trim --left
  | parse 'Active: {state} since {spawned}; {_}'
  | into record
  | update spawned {|row| try { into datetime } catch { $row.spawned } }
}

# Start the IPEX-LLM Ollama server.
@category system
export def serve []: nothing -> record {
  job spawn --description='ipex-llm-ollama_serve' { cd $env.IPEX_LLM_OLLAMA_HOME!; bash start-ollama.sh out+err>| job send 0 }
  print 'server started; run `job recv` to stream output'
  job list | where description starts-with 'ipex-llm-ollama' | first
}
