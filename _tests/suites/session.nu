# `session` with a stub `zellij`: `test _tests/suites/session.nu`.
#
# The stub logs every invocation and answers `list-sessions` from a canned file (an empty file plays "no sessions";
# `--short` prints the names). No real Zellij client or session is touched.
use session
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

const SESSIONS: string = "legal-marketplace [Created 1day 10h 41m 15s ago] \nsrs-drafting [Created 6h 19m 42s ago] (EXITED - attach to resurrect)\nnu-lib [Created 2m 2s ago] (current)\n"

# Run `body` with a stub `zellij` first on PATH. The closure receives {log, sessions}: the invocation log and the
# canned `list-sessions` output file (overwrite it to change the answer; empty it for "no sessions").
def with-stub [body: closure]: nothing -> nothing {
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    let log: path = $ctx.code | path join calls.log
    let sessions: path = $ctx.code | path join sessions.txt
    mkdir $stubs
    $SESSIONS | save --force $sessions
    [
      '#!/bin/sh'
      $"echo \"ZELLIJ:$*\" >> '($log)'"
      'case "$*" in'
      $"  list-sessions*) if [ -s '($sessions)' ]; then case \"$*\" in *--short*) cut -d' ' -f1 '($sessions)';; *) cat '($sessions)';; esac; else echo 'No active zellij sessions found.' >&2; exit 1; fi;;"
      '  "delete-session nope"|"delete-all-sessions --yes --fail") echo "No session named \"nope\" found." >&2; exit 1;;'
      '  *) exit 0;;'
      'esac'
    ] | str join (char newline) | save --force ($stubs | path join zellij)
    ^chmod +x ($stubs | path join zellij)
    with-env {PATH: ($env.PATH | prepend $stubs)} {
      assert equal (which zellij | get $.0.path) ($stubs | path join zellij) 'the stub shadows any real client'
      do $body {log: $log sessions: $sessions}
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
    assert equal $age (31557600sec + 2 * 2629800sec + 3day + 4hr + 5min + 6sec + 7ms) 'years and months are averages'
  }
}

# ——— down ———————————————————————————————————————————————————————————————————————

def "test down kills then deletes one session" []: nothing -> nothing {
  with-stub {|t|
    session down nu-lib
    assert equal (calls $t.log) ['kill-session nu-lib' 'delete-session nu-lib'] 'kill, then delete'
  }
}

def "test down --all never prompts" []: nothing -> nothing {
  with-stub {|t|
    session down --all
    assert equal (calls $t.log) ['kill-all-sessions --yes' 'delete-all-sessions --yes'] '--yes on both'
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

def "test exec splits the command line and forwards run options" []: nothing -> nothing {
  with-stub {|t|
    session exec 'cargo build --release' --floating --name build
    assert equal (calls $t.log | last) 'run --floating --name build -- cargo build --release' 'command, options, --'
    [-la /tmp] | session exec 'ls ignored' --direction right
    assert equal (calls $t.log | last) 'run --direction right -- ls -la /tmp' 'a piped list replaces the split arguments'
    assert equal (code-of { session exec }) 'session::exec::invalid_argument' 'a command line is required'
  }
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
