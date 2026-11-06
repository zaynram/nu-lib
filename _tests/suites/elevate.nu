# `elevate` with stub `sudo` programs: `test _tests/suites/elevate.nu`.
#
# `sudo` is always a stub first on PATH (asserted before use): either one that only prints its arguments, or one
# that runs them unprivileged (`exec "$@"`). `elevate` itself `exec`s, so it runs in a sandboxed child whose
# output is the stub's. `with-auth` runs stub commands; its retry path needs an interactive interpreter.
use elevate
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path, name: path, body: string]: nothing -> path {
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

const PRINT_ARGS: string = 'for a in "$@"; do echo "ARG:$a"; done'

# Run `body` with a stub `sudo` first on PATH: `--mode print` echoes `ARG:<arg>` lines, `--mode run` runs its
# arguments. The closure receives {ctx, stubs, path}: the sandbox, the stub directory and the PATH used.
def with-sudo [body: closure, --mode: string = print]: nothing -> nothing {
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    mkdir $stubs
    stub $stubs sudo (if $mode == print { $PRINT_ARGS } else { 'exec "$@"' }) | ignore
    let path: list<string> = $env.PATH | prepend $stubs
    with-env {PATH: $path} {
      assert equal (which sudo | get 0.path) ($stubs | path join sudo) 'the stub sudo shadows the real one'
      do $body {ctx: $ctx stubs: $stubs path: $path}
    }
  } | ignore
}

# The `ARG:` lines of some output.
def args-of []: oneof<string, nothing> -> list<string> {
  default '' | lines | where $it starts-with 'ARG:' | each { str substring 4.. }
}

# Stub commands for `with-auth`, in `dir`; `authcmd` fails with a 401 until the file `<dir>/token` exists.
def auth-stubs [dir: path]: nothing -> nothing {
  stub $dir okcmd 'echo "out:$*"' | ignore
  stub $dir failcmd 'echo "partial"; echo "boom" >&2; exit 3' | ignore
  let token: path = $dir | path join token
  stub $dir authcmd $"if [ -e '($token)' ]; then echo 'ok:'\"$*\"; else echo 'HTTP 401 Unauthorized' >&2; exit 1; fi"
  | ignore
}

# ——— elevate ——————————————————————————————————————————————————————————————————

def "test elevate execs the current nu through sudo" []: nothing -> nothing {
  with-sudo {|t|
    let res = sandboxed $t.ctx 'elevate' --prelude 'use elevate' --vars {PATH: $t.path}
    assert equal $res.exit_code 0 'the stub exits cleanly'
    assert equal ($res.stdout | args-of) [$nu.current-exe] 'sudo <current-exe>, not `sudo exec`'
  }
}

def "test elevate passes the binary login and arguments" []: nothing -> nothing {
  with-sudo {|t|
    let res = sandboxed $t.ctx "elevate --binary /opt/nu --login=true -c 'print 1'" --prelude 'use elevate' --vars {PATH: $t.path}
    assert equal ($res.stdout | args-of) [/opt/nu --login -c 'print 1'] 'binary, --login, then the arguments'
    let short = sandboxed $t.ctx "elevate -c 'print 1' -b /opt/nu" --prelude 'use elevate' --vars {PATH: $t.path}
    assert equal ($short.stdout | args-of) [/opt/nu -c 'print 1'] '-b is the short form, taken wherever it appears'
  }
}

def "test elevate passes a leading path as an argument" []: nothing -> nothing {
  with-sudo {|t|
    let res = sandboxed $t.ctx 'elevate script.nu' --prelude 'use elevate' --vars {PATH: $t.path}
    assert equal ($res.stdout | args-of) [$nu.current-exe script.nu] 'a positional is an argument for nu, not the binary'
  }
}

def "test elevate follows the login state of the shell" []: nothing -> nothing {
  with-sudo {|t|
    let res = sandboxed $t.ctx 'elevate' --prelude 'use elevate' --vars {PATH: $t.path}
    assert ('--login' not-in ($res.stdout | args-of)) 'a non-login shell elevates without --login'
    let login = with-env {PATH: $t.path} {
      ^$nu.current-exe --no-config-file --login --include-path $ROOT -c 'use elevate; elevate' | complete
    }
    assert equal ($login.stdout | args-of) [$nu.current-exe --login] 'a login shell elevates with --login'
  }
}

def "test elevate passes a leading flag to nu" []: nothing -> nothing {
  with-sudo {|t|
    let res = sandboxed $t.ctx "elevate -c 'print 1'" --prelude 'use elevate' --vars {PATH: $t.path}
    assert equal ($res.stdout | args-of) [$nu.current-exe -c 'print 1'] 'nu flags reach the elevated nu'
  }
}

# ——— elevate sh ———————————————————————————————————————————————————————————————

def "test sh joins the words into a nu command with stdin" []: nothing -> nothing {
  with-sudo {|t|
    let args = elevate sh echo 'hi there' | args-of
    assert equal $args [$nu.current-exe --stdin -c 'echo hi there'] 'sudo nu --stdin -c <words>'
  }
}

def "test sh passes stdin only to nu shells" []: nothing -> nothing {
  with-sudo {|t|
    assert equal (elevate sh --shell /bin/sh ls -s | args-of) [/bin/sh -c 'ls -s'] 'no --stdin for sh; -s passes through'
    assert equal (elevate sh --stdin=false whoami | args-of) [$nu.current-exe -c whoami] 'no --stdin when disabled'
  }
}

def "test sh runs a script with its arguments" []: nothing -> nothing {
  with-sudo {|t|
    let script: path = stub $t.ctx.code job.sh 'exit 0'
    cd $t.ctx.code
    assert equal (elevate sh --shell /bin/sh --script job.sh a b | args-of) [/bin/sh $script a b] 'expanded script path'
    assert error { elevate sh --script missing.sh } 'a missing script is an error'
  }
}

def "test sh returns the command output" []: nothing -> nothing {
  with-sudo --mode run {|t|
    let out = elevate sh --shell /bin/sh echo 'hi there'
    assert equal ($out | str trim) 'hi there' 'the output is returned'
  }
}

def "test sh forwards the pipeline input" []: nothing -> nothing {
  with-sudo --mode run {|t|
    assert equal ('abc' | elevate sh --shell /bin/sh cat) abc 'piped to the shell'
    assert equal ('abc' | elevate sh '$in | str length' | str trim) '3' 'nu reads it as $in'
  }
}

# ——— with-auth ————————————————————————————————————————————————————————————————

def "test with auth returns stdout" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    assert equal (elevate with-auth okcmd a b | str trim) 'out:a b' 'stdout of the command'
  }
}

def "test with auth raises a failing command" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    let err = try { elevate with-auth failcmd x; null } catch {|e| $e }
    assert ($err != null) 'raises'
    assert str contains $err.msg 'exited with code 3' 'names the exit code'
    assert str contains ($err.details.help? | default '') boom 'carries the output'
  }
}

def "test with auth without arguments returns merged output" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    let out = elevate with-auth failcmd
    assert str contains $out partial 'stdout'
    assert str contains $out boom 'stderr is merged in'
  }
}

def "test with auth strict checks without arguments" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    assert error { elevate with-auth --strict failcmd } 'a failure raises'
    assert equal (elevate with-auth --strict okcmd | str trim) 'out:' 'success returns stdout'
  }
}

def "test with auth does not log in outside an interactive session" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    let token: path = $t.stubs | path join token
    let err = try { elevate with-auth --login={|| touch $token } authcmd x; null } catch {|e| $e }
    assert ($err != null) 'the auth failure raises'
    assert str contains ($err.details.help? | default '') Unauthorized 'with the command output'
    assert not ($token | path exists) 'the login closure did not run'
  }
}

def "test with auth logs in and retries in an interactive session" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    let token: path = $t.stubs | path join token
    let code: string = $"use elevate; elevate with-auth --login={|| touch '($token)' } authcmd x | str trim | to nuon"
    let res = ^$nu.current-exe --no-config-file --interactive --include-path $ROOT -c $code | complete
    assert equal $res.exit_code 0 $"the retry succeeds: ($res.stderr)"
    assert equal ($res.stdout | from nuon) 'ok:x' 'the retried output'
    assert ($token | path exists) 'the login closure ran'
  }
}

def "test with auth leaves other failures alone in an interactive session" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    let marker: path = $t.stubs | path join logged-in
    let code: string = $"use elevate; elevate with-auth --login={|| touch '($marker)' } failcmd x"
    let res = ^$nu.current-exe --no-config-file --interactive --include-path $ROOT -c $code | complete
    assert ($res.exit_code != 0) 'the failure is raised'
    assert not ($marker | path exists) 'no login for a non-auth failure'
  }
}

def "test with auth pattern decides what an auth failure is" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    let marker: path = $t.stubs | path join logged-in
    let code: string = $"use elevate; try { elevate with-auth --pattern=boom --login={|| touch '($marker)' } failcmd x }"
    ^$nu.current-exe --no-config-file --interactive --include-path $ROOT -c $code | complete | ignore
    assert ($marker | path exists) 'a custom pattern triggers the login'
  }
}

def "test with auth passes the command flags through" []: nothing -> nothing {
  with-sudo {|t|
    auth-stubs $t.stubs
    assert equal (elevate with-auth okcmd -s -l | str trim) 'out:-s -l' 'short flags belong to the command'
  }
}
