# `ipex-llm-ollama` with stub `systemctl`, `bash` and `ls-sycl-device`: `test _tests/suites/ipex-llm-ollama.nu`.
#
# Nothing touches the real service: `status` reads a stub `systemctl`, `serve` runs a stub `bash` (asserted first
# on PATH) in a sandbox home, and the environment set-up runs in sandboxed children.
use ipex-llm-ollama
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path, name: path, body: string]: nothing -> path {
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

# `ipex-llm-ollama status` against a stub `systemctl` that prints `output` and exits with `code`.
def status-of [output: string, --code: int = 0]: nothing -> record {
  with-sandbox {|ctx|
    let log: path = $ctx.code | path join calls.log
    stub $ctx.code systemctl $"echo \"$*\" >> '($log)'\ncat <<'EOF'\n($output)\nEOF\nexit ($code)" | ignore
    with-env {PATH: ($env.PATH | prepend $ctx.code)} {
      assert equal (which systemctl | get 0.path) ($ctx.code | path join systemctl) 'the stub systemctl is used'
      {status: (ipex-llm-ollama status) calls: (open $log | lines)}
    }
  }
}

# Children must start without the suite's own `IPEX_LLM_OLLAMA_HOME` (set by `use ipex-llm-ollama` above): the
# runner's environment scrub (`hide-env` after a `do --env`) is a no-op inside test children on this nightly.
const PRELUDE: string = 'hide-env --ignore-errors IPEX_LLM_OLLAMA_HOME; use ipex-llm-ollama'

const ACTIVE: string = '● ipex-llm-ollama.service - IPEX-LLM Ollama
     Loaded: loaded (/etc/systemd/system/ipex-llm-ollama.service; enabled; preset: enabled)
     Active: active (running) since Thu 2026-11-05 10:00:00 UTC; 1h 2min ago
   Main PID: 1234 (bash)'

const INACTIVE: string = '○ ipex-llm-ollama.service - IPEX-LLM Ollama
     Loaded: loaded (/etc/systemd/system/ipex-llm-ollama.service; disabled; preset: enabled)
     Active: inactive (dead)'

# ——— environment ——————————————————————————————————————————————————————————————

def "test the default home sits next to the nushell data directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{home: $env.IPEX_LLM_OLLAMA_HOME data: $nu.data-dir path: $env.PATH} | to nuon'
    let r = sandboxed $ctx $code --prelude $PRELUDE --pipe
    let expected: path = $r.data | path dirname | path join ipex-llm-ollama
    assert equal $r.home $expected 'data-dir/../ipex-llm-ollama'
    assert equal ($r.path | last) $expected 'appended to PATH'
  } | ignore
}

def "test a configured home is kept and added to PATH" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{home: $env.IPEX_LLM_OLLAMA_HOME path: $env.PATH} | to nuon'
    let r = sandboxed $ctx $code --prelude 'use ipex-llm-ollama' --vars {IPEX_LLM_OLLAMA_HOME: /opt/ipex} --pipe
    assert equal $r.home /opt/ipex 'the configured home'
    assert ('/opt/ipex' in $r.path) 'on PATH even though the variable was set'
  } | ignore
}

def "test loading twice adds the home once" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = 'use ipex-llm-ollama; $env.PATH | where $it == $env.IPEX_LLM_OLLAMA_HOME | length'
    assert equal (sandboxed $ctx $code --prelude $PRELUDE --pipe) 1 'one PATH entry'
  } | ignore
}

def "test device runs ls sycl device from the home" []: nothing -> nothing {
  with-sandbox {|ctx|
    let home: path = $ctx.code | path join ipex
    mkdir $home
    stub $home ls-sycl-device 'echo "devices:$*"' | ignore
    let r = sandboxed $ctx 'ipex-llm-ollama device --all' --prelude 'use ipex-llm-ollama' --vars {IPEX_LLM_OLLAMA_HOME: $home}
    assert equal ($r.stdout | str trim) 'devices:--all' 'the home is on PATH, arguments pass through'
  } | ignore
}

# ——— status ———————————————————————————————————————————————————————————————————

def "test status asks systemctl for the service" []: nothing -> nothing {
  assert equal (status-of $ACTIVE).calls ['status ipex-llm-ollama --no-pager --lines 0'] 'systemctl arguments'
}

def "test status of an active service" []: nothing -> nothing {
  let s = (status-of $ACTIVE).status
  assert equal $s.state 'active (running)' 'state'
  assert equal $s.spawned ('2026-11-05T10:00:00+00:00' | into datetime) 'spawned is a datetime'
}

def "test status of an inactive service has no spawn time" []: nothing -> nothing {
  assert equal (status-of $INACTIVE --code=3).status {state: 'inactive (dead)' spawned: null} 'no since clause'
}

def "test status keeps an unparsable time as text" []: nothing -> nothing {
  let s = (status-of '     Active: failed (Result: exit-code) since sometime; 5min ago' --code=3).status
  assert equal $s {state: 'failed (Result: exit-code)' spawned: sometime} 'raw text'
}

def "test status of an unknown service is an error" []: nothing -> nothing {
  let err = try { status-of 'Unit ipex-llm-ollama.service could not be found.' --code=4; null } catch {|e| $e }
  assert ($err != null) 'raises'
  assert str contains $err.msg 'no status reported' 'message'
}

# ——— serve ————————————————————————————————————————————————————————————————————

def "test serve runs start ollama in the home and sends its output" []: nothing -> nothing {
  with-sandbox {|ctx|
    let home: path = $ctx.code | path join ipex
    let stubs: path = $ctx.code | path join stubs
    mkdir $home $stubs
    stub $stubs bash 'echo "cwd:$(pwd) args:$*"' | ignore
    with-env {PATH: ($env.PATH | prepend $stubs) IPEX_LLM_OLLAMA_HOME: $home} {
      assert equal (which bash | get 0.path) ($stubs | path join bash) 'the stub bash is used'
      let job = ipex-llm-ollama serve
      assert equal $job.description? ipex-llm-ollama_serve 'returns the job'
      let message = job recv --timeout 10sec
      assert equal ($message | str trim) $"cwd:($home) args:start-ollama.sh" 'output arrives in the mailbox'
    }
  } | ignore
}
