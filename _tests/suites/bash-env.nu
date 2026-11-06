# The vendored `bash-env` module (light coverage of vendored code): `test _tests/suites/bash-env.nu`.
#
# It runs its `bin/bash-env-json` script, which needs `bash` and `jq`.
use bash-env
use ../mod.nu *

def need-tools []: nothing -> nothing {
  for bin in [bash jq] { if (which $bin | is-empty) { skip $'`($bin)` is not installed' } }
}

def "test the script ships with the module" []: nothing -> nothing {
  let script: path = $ROOT | path join bash-env bin bash-env-json
  assert ($script | path exists) 'bin/bash-env-json is vendored next to the module'
  assert ((ls --long $script | first | get mode) =~ 'x') 'and is executable'
}

def "test content returns exported and shell variables" []: nothing -> nothing {
  need-tools
  assert equal (bash-env --content "export SBBE_N=10\nSBBE_X=1") {SBBE_X: '1' SBBE_N: '10'} 'merge is the default'
  assert equal (bash-env --content "export SBBE_N=10\nSBBE_X=1" --return env) {SBBE_N: '10'} 'env only'
  assert equal (bash-env --content "export SBBE_N=10\nSBBE_X=1" --return shellvars) {SBBE_X: '1'} 'shell variables only'
}

def "test a file is sourced" []: nothing -> nothing {
  need-tools
  let vars: record = with-sandbox {|ctx|
    let file: path = $ctx.code | path join vars.sh
    'export SBBE_FILE=yes' | save $file
    bash-env --return env $file
  }
  assert equal $vars {SBBE_FILE: yes} 'variables exported by the file'
}

def "test load sets the environment" []: nothing -> nothing {
  need-tools
  bash-env --content 'export SBBE_LOADED=5' --load | ignore
  assert equal $env.SBBE_LOADED '5' 'exported variables are loaded'
}

def "test functions are captured" []: nothing -> nothing {
  need-tools
  let out: record = bash-env --content 'f() { export SBBE_A=1; }' --execute [f]
  assert equal $out.fn.f.env {SBBE_A: '1'} 'a function environment effect'
}

def "test missing input raises" []: nothing -> nothing {
  assert error {|| bash-env } 'no content or path'
  assert error {|| bash-env /sbbe/missing.sh } 'a missing file'
}
