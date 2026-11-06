# `reload` with a stub `reset` and a stub `--binary`: `test _tests/suites/reload.nu`.
#
# `reload` execs, so every case runs it in a grandchild `nu` whose output is the stub binary's. The terminal reset
# only happens with a terminal on stdin; those cases run the grandchild under `script` (a pseudo-terminal).
use reload
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path, name: path, body: string]: nothing -> path {
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

# Run `body` with a logging stub `reset` first on PATH and a stub binary that prints its arguments and
# environment. The closure receives {ctx, binary, log, path}.
def with-stubs [body: closure]: nothing -> nothing {
  if $nu.os-info.name != linux { skip '`reset` only runs on Linux' }
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    let log: path = $ctx.code | path join reset.log
    mkdir $stubs
    # `tty=` records whether stdin is a terminal: a piped record reaching `reset` shows up as `tty=no`.
    stub $stubs reset $"echo \"RESET:$* tty=$\([ -t 0 ] && echo yes || echo no\)\" >> '($log)'" | ignore
    let binary: path = stub $ctx.code fresh-nu 'echo "ARGS:$*"; echo "FOO=${FOO-unset}"; echo "PID=${pid-unset}"'
    let path: list<string> = $env.PATH | prepend $stubs
    with-env {PATH: $path} {
      assert equal (which reset | get 0.path) ($stubs | path join reset) 'the stub reset shadows the real one'
      do $body {ctx: $ctx binary: $binary log: $log path: $path}
    }
  } | ignore
}

# Run nu `code` (after `use reload`) in a grandchild (extra nu `--flags`) with stdin on a pipe; return its output
# lines.
def run-nu [code: string, --flags: list<string> = []]: nothing -> list<string> {
  let res = '' | ^$nu.current-exe --no-config-file --include-path $ROOT ...$flags -c $"use reload; ($code)" | complete
  assert equal $res.exit_code 0 $"the grandchild succeeds: ($res.stderr)"
  $res.stdout | lines
}

# Run nu `code` (after `use reload`) in a grandchild on a pseudo-terminal; return its output lines.
def run-tty [t: record, code: string]: nothing -> list<string> {
  if (which script | is-empty) { skip '`script` (util-linux) is not installed' }
  let file: path = $t.ctx.code | path join case.nu
  $"use reload; ($code)" | save --force $file
  let command: string = $"'($nu.current-exe)' --no-config-file --include-path '($ROOT)' '($file)'"
  # `--return` relays the grandchild's exit status: a 141 here is the grandchild dying of SIGPIPE, a module bug.
  let res: record = with-env {SHELL: /bin/sh} { ^script --quiet --return --command $command /dev/null | complete }
  assert equal $res.exit_code 0 $"the grandchild succeeds \(exit ($res.exit_code)\): ($res.stdout) ($res.stderr)"
  $res.stdout | lines | str trim
}

def resets [log: path]: nothing -> list<string> {
  if ($log | path exists) { open $log | lines } else { [] }
}

# ——— cases ————————————————————————————————————————————————————————————————————

def "test execs the binary with the arguments" []: nothing -> nothing {
  with-stubs {|t|
    let out = run-nu $"reload --binary '($t.binary)' a 'b c'"
    assert equal ($out | first) 'ARGS:a b c' 'the binary replaces the shell with the arguments'
  }
}

def "test a piped record is merged into the environment" []: nothing -> nothing {
  with-stubs {|t|
    let out = run-nu $"{FOO: hello} | reload --binary '($t.binary)'"
    assert ('FOO=hello' in $out) 'the record reaches the new process'
  }
}

def "test skips the terminal reset without a terminal" []: nothing -> nothing {
  with-stubs {|t|
    run-nu $"reload --binary '($t.binary)'" | ignore
    assert equal (resets $t.log) [] 'reset is not run'
  }
}

def "test resets the terminal on a terminal" []: nothing -> nothing {
  with-stubs {|t|
    let out = run-tty $t $"reload --binary '($t.binary)' x"
    assert ('ARGS:x' in $out) 'the binary still runs'
    assert equal (resets $t.log) ['RESET:-w tty=yes'] 'reset -w, on the terminal'
  }
}

def "test a piped record never reaches reset" []: nothing -> nothing {
  with-stubs {|t|
    let out = run-tty $t $"{FOO: hello} | reload --binary '($t.binary)' x"
    assert ('FOO=hello' in $out) 'the record is loaded into the environment'
    assert equal (resets $t.log) ['RESET:-w tty=yes'] 'reset keeps the terminal as stdin (a pipe would be SIGPIPE at exec)'
  }
}

def "test erase restores control characters too" []: nothing -> nothing {
  with-stubs {|t|
    run-tty $t $"reload --erase --binary '($t.binary)'" | ignore
    assert equal (resets $t.log) ['RESET:-wc tty=yes'] 'reset -wc'
  }
}

def "test a login shell reloads as a login shell" []: nothing -> nothing {
  with-stubs {|t|
    assert equal (run-nu $"reload --binary '($t.binary)' x" | first) 'ARGS:x' 'no --login otherwise'
    assert equal (run-nu $"reload --binary '($t.binary)' x" --flags [--login] | first) 'ARGS:--login x' '--login first'
  }
}

def "test an interactive shell drops pid" []: nothing -> nothing {
  with-stubs {|t|
    let code: string = $"$env.pid = 42; reload --binary '($t.binary)'"
    assert ('PID=42' in (run-nu $code)) 'kept by a non-interactive shell'
    assert ('PID=unset' in (run-nu $code --flags [--interactive])) 'dropped by an interactive shell'
  }
}
