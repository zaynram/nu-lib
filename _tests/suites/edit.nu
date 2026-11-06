# `edit` with a recording stub editor (and a stub `zellij`): `test _tests/suites/edit.nu`.
#
# The editor is `$env.config.buffer_editor` pointed at a stub that appends its working directory and arguments to
# a log; inside Zellij the stub `zellij` logs its calls and serves a canned `list-panes` answer. No real editor or
# Zellij session is touched.
use edit
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path, name: path, body: string]: nothing -> path {
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

# Run `body` in a workspace (top.txt, sub/a.txt, sub/b.txt, sub/deep/c.txt) with stub programs first on PATH.
#
# The closure receives {dir, log, panes}: `dir` is the workspace (also the working directory), `log` collects
# the stubs' output, and `panes` is the JSON file the stub `zellij` prints for `action list-panes`.
def with-workspace [body: closure]: nothing -> nothing {
  with-sandbox {|ctx|
    let dir: path = $ctx.code | path join work
    let stubs: path = $ctx.code | path join stubs
    let log: path = $ctx.code | path join calls.log
    let panes: path = $ctx.code | path join panes.json
    mkdir ($dir | path join sub deep) $stubs
    [top.txt sub/a.txt sub/b.txt sub/deep/c.txt] | each {|f| touch ($dir | path join $f) } | ignore
    '[]' | save $panes
    stub $stubs editor $"{ echo \"EDITOR\"; echo \"CWD:$\(pwd)\"; for a in \"$@\"; do echo \"ARG:$a\"; done; } >> '($log)'"
    | ignore
    stub $stubs zellij ([
      $"echo \"ZELLIJ:$*\" >> '($log)'"
      $"case \"$*\" in 'action list-panes'*) cat '($panes)';; *) echo terminal_9;; esac"
    ] | str join (char newline)) | ignore
    cd $dir
    with-env {PATH: ($env.PATH | prepend $stubs)} {
      $env.config.buffer_editor = 'editor'
      do $body {dir: $dir log: $log panes: $panes}
    }
  } | ignore
}

# The logged editor invocation: {cwd, args}.
def editor-call [log: path]: nothing -> record<cwd: string, args: list<string>> {
  let lines: list<string> = open $log | lines
  {
    cwd: ($lines | where $it starts-with 'CWD:' | first | str substring 4..)
    args: ($lines | where $it starts-with 'ARG:' | each { str substring 4.. })
  }
}

# The logged `zellij` invocations (their argument strings).
def zellij-calls [log: path]: nothing -> list<string> {
  open $log | lines | where $it starts-with 'ZELLIJ:' | each { str substring 7.. }
}

# ——— editor ———————————————————————————————————————————————————————————————————

def "test opens existing files as absolute paths" []: nothing -> nothing {
  with-workspace {|t|
    edit top.txt sub/a.txt
    let call = editor-call $t.log
    assert equal $call.args [($t.dir | path join top.txt) ($t.dir | path join sub a.txt)] 'expanded, in order'
    assert equal $call.cwd $t.dir 'runs in the working directory'
  }
}

def "test a new file is passed to the editor" []: nothing -> nothing {
  with-workspace {|t|
    edit new.txt
    assert equal (editor-call $t.log).args [($t.dir | path join new.txt)] 'the editor receives the new path'
  }
}

def "test glob patterns expand to sorted matches" []: nothing -> nothing {
  with-workspace {|t|
    edit 'sub/*.txt'
    let expected: list<path> = [($t.dir | path join sub a.txt) ($t.dir | path join sub b.txt)]
    assert equal (editor-call $t.log).args $expected 'both matches, sorted'
  }
}

def "test depth limits glob recursion" []: nothing -> nothing {
  with-workspace {|t|
    edit '**/*.txt'
    assert equal (editor-call $t.log).args [($t.dir | path join top.txt)] 'depth 1 by default'
    rm $t.log
    edit --depth 3 '**/*.txt'
    assert equal ((editor-call $t.log).args | length) 4 'depth 3 reaches sub/deep'
  }
}

def "test file and line items pass through verbatim" []: nothing -> nothing {
  with-workspace {|t|
    edit top.txt:12
    assert equal (editor-call $t.log).args [top.txt:12] 'not expanded'
  }
}

def "test cd sets the editor directory and resolves items against it" []: nothing -> nothing {
  with-workspace {|t|
    edit --cd sub a.txt
    let call = editor-call $t.log
    assert equal $call.args [($t.dir | path join sub a.txt)] 'resolved against --cd'
    assert equal $call.cwd ($t.dir | path join sub) 'the editor runs in --cd'
    assert equal $env.PWD $t.dir 'the caller stays where it was'
  }
}

def "test piped records and tables supply paths" []: nothing -> nothing {
  with-workspace {|t|
    [[name]; [top.txt]] | edit
    assert equal (editor-call $t.log).args [($t.dir | path join top.txt)] 'name column'
    rm $t.log
    {path: sub/a.txt} | edit
    assert equal (editor-call $t.log).args [($t.dir | path join sub a.txt)] 'path field'
    rm $t.log
    [{filename: sub/b.txt} {other: x}] | edit
    assert equal (editor-call $t.log).args [($t.dir | path join sub b.txt)] 'filename field; rows without one are dropped'
    rm $t.log
    'top.txt' | edit sub/a.txt
    assert equal ((editor-call $t.log).args | path basename) [top.txt a.txt] 'piped items come before arguments'
  }
}

def "test no items opens the working directory" []: nothing -> nothing {
  with-workspace {|t|
    edit
    assert equal (editor-call $t.log).args [$t.dir] 'the working directory'
    rm $t.log
    edit '*.none'
    assert equal (editor-call $t.log).args [$t.dir] 'a glob without matches resolves to nothing'
  }
}

def "test a list buffer editor supplies arguments" []: nothing -> nothing {
  with-workspace {|t|
    $env.config.buffer_editor = [editor --flag]
    edit top.txt
    assert equal (editor-call $t.log).args [--flag ($t.dir | path join top.txt)] 'program arguments first'
  }
}

def "test EDITOR is the fallback editor" []: nothing -> nothing {
  with-workspace {|t|
    $env.config.buffer_editor = null
    with-env {EDITOR: editor} { edit top.txt }
    assert equal (editor-call $t.log).args [($t.dir | path join top.txt)] 'EDITOR runs'
  }
}

# ——— zellij ———————————————————————————————————————————————————————————————————

def "test zellij opens one file in place" []: nothing -> nothing {
  with-workspace {|t|
    with-env {ZELLIJ: '0'} { edit top.txt }
    let calls = zellij-calls $t.log
    assert equal ($calls | first) 'action list-panes --json --command' 'looks for an editor pane'
    assert equal ($calls | last) $"edit --in-place --cwd ($t.dir) ($t.dir | path join top.txt)" 'zellij edit'
    assert equal ($calls | length) 2 'no pane to focus'
  }
}

def "test zellij runs the editor for several files" []: nothing -> nothing {
  with-workspace {|t|
    with-env {ZELLIJ: '0'} { edit sub/b.txt top.txt }
    let expected: string = [
      'run --name=Editing: b, ... --in-place --close-on-exit'
      $"--cwd ($t.dir) -- editor ($t.dir | path join sub b.txt) ($t.dir | path join top.txt)"
    ] | str join ' '
    assert equal (zellij-calls $t.log | last) $expected 'zellij run, files in the given order'
  }
}

def "test zellij focuses an existing editor pane first" []: nothing -> nothing {
  with-workspace {|t|
    [
      {id: 1 is_plugin: true is_suppressed: false title: editor}
      {id: 2 is_plugin: false is_suppressed: true title: editor}
      {id: 3 is_plugin: false is_suppressed: false title: shell pane_command: nu}
      {id: 4 is_plugin: false is_suppressed: false title: 'Editing: x, ...'}
    ] | to json | save --force $t.panes
    with-env {ZELLIJ: '0'} { edit top.txt }
    assert equal (zellij-calls $t.log | get 1) 'action focus-pane-id terminal_4' 'skips plugin and suppressed panes'
  }
}

def "test zellij recognises a pane running the editor" []: nothing -> nothing {
  with-workspace {|t|
    [{id: 7 is_plugin: false is_suppressed: false title: work pane_command: 'editor notes.md'}]
    | to json | save --force $t.panes
    with-env {ZELLIJ: '0'} { edit top.txt }
    assert equal (zellij-calls $t.log | get 1) 'action focus-pane-id terminal_7' 'matched by command'
  }
}
