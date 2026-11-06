# `session` with a stub `zellij`: `test _tests/suites/session.nu`.
#
# The stub logs every invocation and answers `list-sessions` from a canned file (an empty file plays "no sessions";
# `--short` prints the names); any invocation listed in the fail file exits 1. No real Zellij client or session is
# touched.
use session
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

const SESSIONS: string = "legal-marketplace [Created 1day 10h 41m 15s ago] \nsrs-drafting [Created 6h 19m 42s ago] (EXITED - attach to resurrect)\nnu-lib [Created 2m 2s ago] (current)\n"

# Run `body` with a stub `zellij` first on PATH. The closure receives {log, sessions, fail}: the invocation log, the
# canned `list-sessions` output file (overwrite it to change the answer; empty it for "no sessions") and the fail
# file (one argument string per line; a matching invocation fails with `sbzellij: <args> failed` on stderr).
def with-stub [body: closure]: nothing -> nothing {
  need-posix
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    let log: path = $ctx.code | path join calls.log
    let sessions: path = $ctx.code | path join sessions.txt
    let fail: path = $ctx.code | path join fail.txt
    mkdir $stubs
    $SESSIONS | save --force $sessions
    [
      '#!/bin/sh'
      $"echo \"ZELLIJ:$*\" >> '($log)'"
      $"if [ -f '($fail)' ] && grep -qxF -- \"$*\" '($fail)'; then echo \"sbzellij: $* failed\" >&2; exit 1; fi"
      'case "$*" in'
      $"  list-sessions*) if [ -s '($sessions)' ]; then case \"$*\" in *--short*) cut -d' ' -f1 '($sessions)';; *) cat '($sessions)';; esac; else echo 'No active zellij sessions found.' >&2; exit 1; fi;;"
      '  "delete-session --force nope") echo "No session named \"nope\" found." >&2; exit 1;;'
      '  *) exit 0;;'
      'esac'
    ] | str join (char newline) | save --force ($stubs | path join zellij)
    ^chmod +x ($stubs | path join zellij)
    with-env {PATH: ($env.PATH | prepend $stubs)} {
      assert equal (which zellij | get $.0.path) ($stubs | path join zellij) 'the stub shadows any real client'
      do $body {log: $log sessions: $sessions fail: $fail}
    }
  } | ignore
}

# The logged `zellij` invocations (their argument strings).
def calls [log: path]: nothing -> list<string> {
  if ($log | path exists) { open $log | lines | each { str substring 7.. } } else { [] }
}

# The error code `code` raises.
def code-of [code: closure]: nothing -> string {
  try { do $code; 'no error' } catch {|e| $e.details?.code? | default $e.msg }
}

# ——— list ———————————————————————————————————————————————————————————————————————

def "test list parses names, ages and statuses" []: nothing -> nothing {
  with-stub {|t|
    let rows = session list
    assert equal ($rows | get $.name) [legal-marketplace srs-drafting nu-lib] 'names, trimmed'
    assert equal ($rows | get $.age) [(1day + 10hr + 41min + 15sec) (6hr + 19min + 42sec) (2min + 2sec)] 'ages as durations'
    assert equal ($rows | get $.status) [active exited active] '(current) and nothing are active; EXITED is exited'
    assert equal (calls $t.log) ['list-sessions --no-formatting'] 'one client call'
  }
}

def "test list filters by pattern and status" []: nothing -> nothing {
  with-stub {|t|
    assert equal (session list --short) [legal-marketplace srs-drafting nu-lib] '--short gives the names'
    assert equal (session list 'nu|srs' --short) [srs-drafting nu-lib] 'the pattern is a regex on the name'
    assert equal (session list --active --short) [legal-marketplace nu-lib] '--active'
    assert equal (session list --exited --short) [srs-drafting] '--exited'
    assert equal (session list --active --exited --short) [legal-marketplace srs-drafting nu-lib] 'both flags: everything'
  }
}

def "test list is empty without sessions" []: nothing -> nothing {
  with-stub {|t|
    '' | save --force $t.sessions
    assert equal (session list) [] "the client's 'no sessions' failure is an empty table"
    assert equal (session list --short) [] 'and an empty name list'
  }
}

def "test list parses every humantime unit" []: nothing -> nothing {
  with-stub {|t|
    "old [Created 1year 2months 3days 4h 5m 6s 7ms ago] \n" | save --force $t.sessions
    let age = session list | get $.0.age
    assert equal $age (31557600sec + 2 * 2630016sec + 3day + 4hr + 5min + 6sec + 7ms) 'years and months are humantime averages (365.25 and 30.44 days)'
  }
}

# ——— the client ———————————————————————————————————————————————————————————————————

def "test every command raises missing_dependency without a client" []: nothing -> nothing {
  with-sandbox {|ctx|
    let empty: path = $ctx.code | path join empty
    mkdir $empty
    with-env {PATH: [$empty]} {
      assert (which zellij | is-empty) 'no client on PATH'
      let codes: list<string> = [
        { session list }
        { session down --all }
        { session switch nu-lib }
        { session manage --session nu-lib new-pane }
        { session exec 'cargo build' }
        { session enter nu-lib }
        { session enter nu-lib --attach=false }
      ] | each {|c| null | code-of $c } # `null |`: the closure's input must not reach `do`
      assert equal ($codes | uniq) ['session::need-client::missing_dependency'] $'one error for all of them: ($codes)'
    }
  }
}

# ——— down ———————————————————————————————————————————————————————————————————————

def "test down kills and deletes one session in one call" []: nothing -> nothing {
  with-stub {|t|
    session down nu-lib
    assert equal (calls $t.log) ['delete-session --force nu-lib'] 'a forced delete, no separate kill to race'
  }
}

def "test down --all never prompts" []: nothing -> nothing {
  with-stub {|t|
    session down --all
    assert equal (calls $t.log) ['delete-all-sessions --yes --force'] '--yes and --force, in one call'
  }
}

def "test down --all reports a failed delete" []: nothing -> nothing {
  with-stub {|t|
    'delete-all-sessions --yes --force' | save --force $t.fail
    assert equal (code-of { session down --all }) 'session::down::external_failure' 'the code'
    let err = try { session down --all } catch {|e| $e }
    assert str contains ($err.details?.help? | default '') 'sbzellij: delete-all-sessions --yes --force failed' 'the client message is the advice'
  }
}

def "test down needs a name or --all" []: nothing -> nothing {
  with-stub {|t|
    assert equal (code-of { session down }) 'session::down::invalid_argument' 'the code'
    assert equal (calls $t.log) [] 'nothing was run'
  }
}

def "test down reports a failed delete" []: nothing -> nothing {
  with-stub {|t|
    assert equal (code-of { session down nope }) 'session::down::external_failure' 'the delete failed'
    let err = try { session down nope } catch {|e| $e }
    assert str contains ($err.details?.help? | default '') 'No session named "nope"' 'the client message is the advice'
  }
}

# ——— switch / manage / exec ———————————————————————————————————————————————————

def "test switch passes the name and extra arguments" []: nothing -> nothing {
  with-stub {|t|
    session switch nu-lib --extra x
    assert equal (calls $t.log) ['action switch-session nu-lib --extra x'] 'as given'
  }
}

def "test manage targets the session explicitly, from the shell, or fails" []: nothing -> nothing {
  with-stub {|t|
    session manage --session nu-lib new-pane
    assert equal (calls $t.log | last) '--session=nu-lib action new-pane' '--session names it'
    with-env {ZELLIJ_SESSION_NAME: srs-drafting} { session manage new-pane -d right }
    assert equal (calls $t.log | last) '--session=srs-drafting action new-pane -d right' 'ZELLIJ_SESSION_NAME names it'
    with-env {ZELLIJ: '0' ZELLIJ_SESSION_NAME: srs-drafting} { session manage new-pane }
    assert equal (calls $t.log | last) 'action new-pane' 'inside a session the client needs no name'
    assert equal (code-of { session manage new-pane }) 'session::manage::invalid_argument' 'outside, without a name'
  }
}

def "test manage leaves the action -s to the action" []: nothing -> nothing {
  with-stub {|t|
    session manage --session nu-lib new-pane -s --floating
    assert equal (calls $t.log | last) '--session=nu-lib action new-pane -s --floating' '-s is not a short --session'
    with-env {ZELLIJ: '0'} { session manage new-pane -s --floating }
    assert equal (calls $t.log | last) 'action new-pane -s --floating' 'nor is it swallowed inside a session'
  }
}

def "test exec splits the command line and forwards run options" []: nothing -> nothing {
  with-stub {|t|
    session exec 'cargo build --release' --floating --name build
    assert equal (calls $t.log | last) 'run --floating --name build -- cargo build --release' 'command, options, --'
    [-la /tmp] | session exec 'ls ignored' --direction right
    assert equal (calls $t.log | last) 'run --direction right -- ls -la /tmp' 'a piped list replaces the split arguments'
    assert equal (code-of { session exec }) 'session::exec::invalid_argument' 'a command line is required'
  }
}

def "test exec rejects a command line without a program" []: nothing -> nothing {
  with-stub {|t|
    assert equal (code-of { session exec '' }) 'session::exec::invalid_argument' 'an empty command line'
    assert equal (code-of { session exec '   ' --floating }) 'session::exec::invalid_argument' 'a blank one'
    assert equal (code-of { [-la] | session exec ' ' }) 'session::exec::invalid_argument' 'the piped list never names the program'
    assert equal (calls $t.log) [] 'nothing was run'
  }
}

def "test exec wants the command line before the run options" []: nothing -> nothing {
  with-stub {|t|
    assert equal (code-of { session exec --floating 'cargo build' }) 'session::exec::invalid_argument' 'a leading flag is not a program'
    assert equal (calls $t.log) [] 'nothing was run'
  }
}

def "test layout completions include symlinked layouts" []: nothing -> nothing {
  need-posix
  with-sandbox {|ctx|
    let layouts: path = $ctx.config | path join zellij layouts
    mkdir $layouts
    'layout {}' | save ($ctx.code | path join real.kdl)
    ^ln -s ($ctx.code | path join real.kdl) ($layouts | path join linked.kdl)
    'layout {}' | save ($layouts | path join plain.kdl)
    # `_layouts` is a private completer: a child that `source`s the module file can call it.
    let program: string = $"source ($ROOT | path join session mod.nu | to nuon); _layouts | to nuon"
    let res = with-env {ZELLIJ_CONFIG_DIR: ($ctx.config | path join zellij)} {
      ^$nu.current-exe --no-config-file --include-path $ROOT --commands $program | complete
    }
    assert equal $res.exit_code 0 $res.stderr
    assert equal ($res.stdout | from nuon | sort) [linked plain] 'a layout that is a symlink is offered too'
  } | ignore
}

# ——— enter ——————————————————————————————————————————————————————————————————————

def "test enter attaches and creates by default" []: nothing -> nothing {
  with-stub {|t|
    session enter nu-lib
    assert equal (calls $t.log | last) 'attach --create nu-lib' 'attach --create <name>'
    session enter nu-lib --layout dev --force-run-commands
    assert equal (calls $t.log | last) 'attach --create nu-lib --force-run-commands options --default-layout dev' 'extra arguments, then the layout as attach options'
    session enter
    assert equal (calls $t.log | last) 'attach --create' 'without a name zellij picks one'
  }
}

def "test enter without attaching starts a session" []: nothing -> nothing {
  with-stub {|t|
    session enter nu-lib --attach=false --layout dev
    assert equal (calls $t.log | last) '--session nu-lib --new-session-with-layout dev' 'a fresh session with the layout'
    session enter --attach=false
    assert equal (calls $t.log | last) '' 'nothing to pass: a plain client start'
    session enter nu-lib --attach=false --layout dev --debug
    assert equal (calls $t.log | last) '--session nu-lib --new-session-with-layout dev --debug' 'the further arguments reach the client here too'
  }
}

def "test enter has no short attach flag" []: nothing -> nothing {
  with-stub {|t|
    # `--attach` takes a value, so a short `-a` could only ever be a parse error: the client gets it instead.
    let res = ^$nu.current-exe --no-config-file --include-path $ROOT --commands 'use session; session enter nu-lib -a' | complete
    assert equal $res.exit_code 0 $"the line parses: ($res.stderr | str trim)"
    assert equal (calls $t.log | last) 'attach --create nu-lib -a' '-a reaches `zellij attach`'
  }
}

def "test enter falls back to ZELLIJ_AUTO_SESSION" []: nothing -> nothing {
  with-stub {|t|
    with-env {ZELLIJ_AUTO_SESSION: auto} { session enter }
    assert equal (calls $t.log | last) 'attach --create auto' 'the environment names the session'
    with-env {ZELLIJ_AUTO_SESSION: auto} { session enter other }
    assert equal (calls $t.log | last) 'attach --create other' 'an explicit name wins'
  }
}
