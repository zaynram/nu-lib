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

# ——— parity corpus ————————————————————————————————————————————————————————————

# `_tests/fixtures/env/from-bash` pins what bash-env returns for a corpus of scripts, so that a replacement can be
# checked against it case by case.
const CORPUS: path = $FIXTURES | path join env from-bash
const BIN: path = $ROOT | path join bash-env bin bash-env-json
const INHERITED: record = {SBFB_KEEP: keep SBFB_GONE: gone SBFB_UNEX: unex}

# The pinned case, with <PATH> and <PWD> resolved for this shell.
def pinned [case: string]: nothing -> record {
  let json = {|s: string| $s | to json | str substring 1..-2 }
  open --raw ($CORPUS | path join parity.nuon)
  | str replace --all '<PATH>' (do $json ($env.PATH | str join (char esep)))
  | str replace --all '<PWD>' (do $json $env.PWD)
  | from nuon
  | get $case
}

# Run a corpus script through bash-env and compare with the pinned output (or, for a failing script, the pinned
# cause that bash-env-json reports).
def parity [case: string]: nothing -> nothing {
  need-tools
  let pin: record = pinned $case
  let file: path = $CORPUS | path join $"($case).sh"
  if $pin.error? == null {
    let out: record = with-env $INHERITED { bash-env --return preserve --execute $pin.execute $file }
    assert equal $out $pin.output $'the pinned output of ($case).sh'
  } else {
    assert error {|| with-env $INHERITED { bash-env --return preserve --execute $pin.execute $file } } 'the script fails'
    let args: list<string> = if $pin.execute == [] { [] } else { [--shellfns ($pin.execute | str join ',')] }
    let res: record = with-env $INHERITED { open --raw $file | ^$BIN ...$args | complete }
    assert equal ($res.stdout | from json | get error) $pin.error $'the pinned cause for ($case).sh'
  }
}

def "test parity plain values" []: nothing -> nothing { parity plain }
def "test parity special values" []: nothing -> nothing { parity special-values }
def "test parity shell variables" []: nothing -> nothing { parity shellvars }
def "test parity removed variables" []: nothing -> nothing { parity removed }
def "test parity path" []: nothing -> nothing { parity path }
def "test parity functions" []: nothing -> nothing { parity functions }
def "test parity empty script" []: nothing -> nothing { parity empty }
def "test parity comments and output only" []: nothing -> nothing { parity comments-only }
def "test parity failing script" []: nothing -> nothing { parity failing }
def "test parity syntax error" []: nothing -> nothing { parity syntax-error }
def "test parity failing function" []: nothing -> nothing { parity failing-function }
def "test parity cd" []: nothing -> nothing { parity cd }
def "test parity return" []: nothing -> nothing { parity return }
def "test parity allexport" []: nothing -> nothing { parity allexport }
def "test parity exported function" []: nothing -> nothing { parity exported-function }
