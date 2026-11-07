# `windows` (WSL helpers) with stub Windows programs: `test _tests/suites/windows.nu`.
#
# No Windows binary ever runs: `where.exe`, `powershell.exe` and `wslpath` are stubs first on PATH (asserted
# before use), and the stub `wslpath` maps drive `C:` to `<sandbox>/c` instead of `/mnt/c`. The `win env` cache
# lives in the sandboxed data directory and is removed at the start of every case.
use windows *
use ../mod.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

# Write an executable shell script `name` with `body` into `dir`.
def stub [dir: path name: path body: string]: nothing -> path {
  need-posix
  let file: path = $dir | path join $name
  $"#!/bin/sh\n($body)\n" | save --force $file
  ^chmod +x $file
  $file
}

const CACHE: path = $nu.data-dir | path join windows_env.msgpack

# The cache tests write `$nu.data-dir`, fixed at startup: under `--no-sandbox` that is the user's real data dir.
def need-sandboxed-data-dir []: nothing -> nothing {
  if $nu.data-dir !~ 'nutest-sandbox' { skip 'needs a sandboxed data dir (run without --no-sandbox)' }
}

# Children must start without the suite's own WINPATH/WSL_DISTRO_NAME (set by `use windows` above). The runner
# scrubs with `env -i` where an `env` program exists; this is belt and braces for the `hide-env` fallback.
const PRELUDE: string = 'hide-env --ignore-errors WINPATH WSL_DISTRO_NAME; use windows *'

# Run `body` with stub `wslpath`, `where.exe` and `powershell.exe` first on PATH, an empty WINPATH, and
# USERPROFILE at `<mnt>/c/Users/me`. The closure receives {ctx, mnt, stubs, log, home}: `mnt` stands in for
# `/mnt`, `log` collects the stubs' calls.
def with-win [body: closure]: nothing -> nothing {
  if $nu.os-info.name != linux { skip 'WSL helpers' }
  # Every case under here may read or write the cache at `$nu.data-dir`: never the user's real one.
  need-sandboxed-data-dir
  rm --force $CACHE
  with-sandbox {|ctx|
    let stubs: path = $ctx.code | path join stubs
    let mnt: path = $ctx.code | path join mnt
    let log: path = $ctx.code | path join calls.log
    let home: path = $mnt | path join c Users me
    mkdir $stubs $home
    stub $stubs wslpath ([
      $"echo \"wslpath $*\" >> '($log)'"
      'case "$2" in bad*) echo "wslpath: $2: Invalid argument" >&2; exit 1;; esac'
      'case "$1" in'
      $"  -u\) printf '%s\\n' \"$2\" | sed -E 's#\\\\#/#g; s#^\([A-Za-z]\):#($mnt)/\\L\\1#' ;;"
      $"  -m\) printf '%s\\n' \"$2\" | sed -E 's#^($mnt)/\([a-z]\)#\\U\\1:#' ;;"
      'esac'
    ] | str join (char newline)) | ignore
    stub $stubs where.exe ([
      $"echo \"where.exe $*\" >> '($log)'"
      'case "$1" in'
      "  hello) printf 'C:\\\\Tools\\\\hello.exe\\r\\nC:\\\\Other\\\\hello.exe\\r\\n' ;;"
      "  bye) printf 'C:\\\\Tools\\\\bye.exe\\r\\n' ;;"
      "  *) echo 'INFO: Could not find files for the given pattern(s).' >&2; exit 1 ;;"
      'esac'
    ] | str join (char newline)) | ignore
    stub $stubs powershell.exe ([
      $"echo \"powershell.exe $*\" >> '($log)'"
      "printf 'C:\\\\Windows;C:\\\\Tools;;%%SystemRoot%%\\\\x\\r\\n'"
    ] | str join (char newline)) | ignore
    let vars: record = {PATH: ($env.PATH | prepend $stubs) WINPATH: [] USERPROFILE: $home}
    with-env $vars {
      for exe in [wslpath where.exe powershell.exe] {
        assert equal (which --all $exe | get $.0.path) ($stubs | path join $exe) $"the stub ($exe) shadows the real one"
      }
      do $body {ctx: $ctx mnt: $mnt stubs: $stubs log: $log home: $home}
    }
  } | ignore
}

def calls [log: path]: nothing -> list<string> {
  if ($log | path exists) { open $log | lines } else { [] }
}

# ——— environment ——————————————————————————————————————————————————————————————

def "test loading moves windows mounts from PATH to WINPATH" []: nothing -> nothing {
  with-sandbox {|ctx|
    let path: list<string> = [/usr/bin /bin /mnt/c/Windows/System32 /home/u/mnt/c/bin /mnt/d/Tools /bin]
    let r = sandboxed $ctx '{PATH: $env.PATH WINPATH: $env.WINPATH} | to nuon' --prelude $PRELUDE --vars {PATH: $path} --pipe
    assert equal $r.PATH [/usr/bin /bin /home/u/mnt/c/bin] 'everything else stays, deduplicated'
    assert equal $r.WINPATH [/mnt/c/Windows/System32 /mnt/d/Tools] 'drive mounts move'
  } | ignore
}

def "test an existing WINPATH leaves PATH alone" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{PATH: $env.PATH WINPATH: $env.WINPATH} | to nuon'
    let prelude: string = 'hide-env --ignore-errors WSL_DISTRO_NAME; $env.WINPATH = [/mnt/c/X]; use windows *'
    let r = sandboxed $ctx $code --prelude $prelude --vars {PATH: [/usr/bin /mnt/c/Y]} --pipe
    assert equal $r {PATH: [/usr/bin /mnt/c/Y] WINPATH: [/mnt/c/X]} 'unchanged'
  } | ignore
}

def "test the distro name defaults to the first word of the os name" []: nothing -> nothing {
  with-sandbox {|ctx|
    let code: string = '{name: $env.WSL_DISTRO_NAME host: (sys host | get name | split words | first)} | to nuon'
    let r = sandboxed $ctx $code --prelude $PRELUDE --pipe
    assert equal $r.name $r.host 'first word of the host name'
    let kept = sandboxed $ctx '$env.WSL_DISTRO_NAME | to nuon' --prelude "hide-env --ignore-errors WINPATH; $env.WSL_DISTRO_NAME = 'Arch'; use windows *" --pipe
    assert equal $kept Arch 'an existing name is kept'
  } | ignore
}

# ——— path conversion ——————————————————————————————————————————————————————————

def "test as posix converts windows paths and passes posix paths through" []: nothing -> nothing {
  with-win {|t|
    assert equal ('C:\Users\me' | path as-posix) ($t.mnt | path join c Users me) 'wslpath -u'
    assert equal ('/home/me/x' | path as-posix) /home/me/x 'unchanged'
    assert equal (calls $t.log) ['wslpath -u C:\Users\me'] 'wslpath only for the windows path'
  }
}

def "test as windows converts posix paths" []: nothing -> nothing {
  with-win {|t|
    assert equal ($t.mnt | path join c x | path as-windows) 'C:/x' 'wslpath -m'
  }
}

def "test conversions map lists and drop failures" []: nothing -> nothing {
  with-win {|t|
    assert equal (['C:\a' 'bad:x' /b] | path as-posix) [($t.mnt | path join c a) /b] 'a failure is dropped from a list'
    assert equal ('bad' | path as-windows) null 'a single failure is null'
  }
}

# ——— win which / win run ——————————————————————————————————————————————————————

def "test which resolves a name through where exe" []: nothing -> nothing {
  with-win {|t|
    assert equal (win which hello) ($t.mnt | path join c Tools hello.exe) 'the first match, as a posix path'
    assert ('where.exe hello' in (calls $t.log)) 'asks where.exe'
  }
}

def "test which all returns every match" []: nothing -> nothing {
  with-win {|t|
    let expected: list<path> = [($t.mnt | path join c Tools hello.exe) ($t.mnt | path join c Other hello.exe)]
    assert equal (win which --all hello) $expected 'every line, CRs trimmed'
  }
}

def "test which of several names returns a record" []: nothing -> nothing {
  with-win {|t|
    let expected: record = {hello: ($t.mnt | path join c Tools hello.exe) bye: ($t.mnt | path join c Tools bye.exe) nope: null}
    assert equal (win which hello bye nope) $expected 'one entry per name'
  }
}

def "test which without names returns nothing" []: nothing -> nothing {
  with-win {|t|
    assert equal (win which) null 'nothing'
    assert equal (calls $t.log) [] 'where.exe is not run'
  }
}

def "test which of a missing command is null and quiet" []: nothing -> nothing {
  with-win {|t|
    let res = sandboxed $t.ctx 'win which nope | to nuon' --prelude $PRELUDE --vars {PATH: $env.PATH}
    assert equal ($res.stdout | str trim) 'null' 'null'
    assert equal ($res.stderr | str trim) '' "where.exe's INFO line does not leak"
  }
}

def "test run executes the resolved program" []: nothing -> nothing {
  with-win {|t|
    mkdir ($t.mnt | path join c Tools)
    stub ($t.mnt | path join c Tools) hello.exe 'echo "hello:$*"' | ignore
    assert equal (win run hello a 'b c' | str trim) 'hello:a b c' 'runs with the arguments'
  }
}

def "test run of a missing command is an error" []: nothing -> nothing {
  with-win {|t|
    let err = try { win run nope; null } catch {|e| $e }
    assert equal $err.msg "command not found: 'nope'" 'error message'
    assert equal $err.details?.code? windows::win-run::not_found 'the code'
  }
}

# ——— win env ——————————————————————————————————————————————————————————————————

const PATHEXT: string = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.CPL'

def "test env merges the windows path after the current path" []: nothing -> nothing {
  with-win {|t|
    let r = with-env {PATH: [/a /b] WINPATH: [/mnt/c/W /a]} { win env }
    assert equal $r {PATH: [/a /b /mnt/c/W] PATHEXT: $PATHEXT USERPROFILE: $t.home} 'merged and deduplicated'
  }
}

def "test env overwrite returns only the windows path" []: nothing -> nothing {
  with-win {|t|
    let r = with-env {PATH: [/a] WINPATH: [/mnt/c/W]} { win env --path overwrite }
    assert equal $r.PATH [/mnt/c/W] 'windows entries only'
  }
}

def "test env caches the raw windows variables" []: nothing -> nothing {
  need-sandboxed-data-dir
  with-win {|t|
    with-env {PATH: [/a] WINPATH: [/mnt/c/W]} {
      win env | ignore
      assert equal (open $CACHE | from msgpack).PATH [/mnt/c/W] 'the cache holds the windows PATH only'
      assert equal (win env --path overwrite).PATH [/mnt/c/W] 'a later --path mode applies to the cached value'
      assert equal (win env).PATH [/a /mnt/c/W] 'and merge again'
    }
  }
}

def "test env reuses the cache until reset" []: nothing -> nothing {
  need-sandboxed-data-dir
  with-win {|t|
    with-env {PATH: [/a] WINPATH: [/mnt/c/W]} { win env | ignore }
    with-env {PATH: [/a] WINPATH: [/mnt/c/X]} {
      assert equal (win env --path overwrite).PATH [/mnt/c/W] 'cached'
      assert equal (win env --path overwrite --reset).PATH [/mnt/c/X] 'recomputed'
      assert equal (win env --path overwrite).PATH [/mnt/c/X] 'and cached again'
    }
  }
}

def "test env rejects an unknown path mode even when cached" []: nothing -> nothing {
  with-win {|t|
    with-env {WINPATH: [/mnt/c/W]} {
      assert error { win env --path bogus } 'before caching'
      win env | ignore
      let err = try { win env --path bogus; null } catch {|e| $e }
      assert equal $err.msg "unknown --path 'bogus'" 'after caching'
      assert equal $err.details?.code? windows::win-env::invalid_argument 'the code'
    }
  }
}

def "test env reads the windows path from powershell without WINPATH" []: nothing -> nothing {
  with-win {|t|
    let r = with-env {PATH: ($env.PATH | prepend /a)} { win env --path overwrite }
    assert equal $r.PATH [($t.mnt | path join c Windows) ($t.mnt | path join c Tools)] 'empty and %VAR% entries dropped'
    assert ((calls $t.log) has 'powershell.exe -nop -noni -ExecutionPolicy Bypass -c $env:PATH') 'asks powershell'
  }
}

def "test env defaults USERPROFILE and PATHEXT" []: nothing -> nothing {
  with-win {|t|
    let r = with-env {WINPATH: [/mnt/c/W] USERPROFILE: '' PATHEXT: null} { win env --vars [$.USERPROFILE $.PATHEXT] }
    assert equal $r {USERPROFILE: $"/mnt/c/Users/($env.USER)" PATHEXT: $PATHEXT} 'defaults'
    let s = with-env {WINPATH: [/mnt/c/W] PATHEXT: '.EXE'} { win env --reset --vars [$.PATHEXT] }
    assert equal $s {PATHEXT: '.EXE'} 'the environment wins'
  }
}

def "test env deep merges a piped record first" []: nothing -> nothing {
  with-win {|t|
    let r = with-env {PATH: [/a] WINPATH: [/mnt/c/W]} { {PATH: [/x] FOO: bar} | win env --vars [$.PATH $.FOO] }
    assert equal $r {PATH: [/x /a /mnt/c/W] FOO: bar} 'lists prepended, new keys added'
  }
}

# Runs in a child: `hide-env` is a no-op inside test children on this nightly (see PRELUDE).
def "test env load sets the variables and drops WINPATH" []: nothing -> nothing {
  with-win {|t|
    let code: string = [
      '$env.PATH = [/a]; $env.WINPATH = [/mnt/c/W]'
      'win env --load'
      'let first = {path: $env.PATH profile: $env.USERPROFILE winpath: ($env has WINPATH)}'
      'win env --load'
      '{first: $first again: $env.PATH} | to nuon'
    ] | str join (char newline)
    let r = sandboxed $t.ctx $code --prelude $PRELUDE --vars {USERPROFILE: $t.home} --pipe
    assert equal $r.first {path: [/a /mnt/c/W] profile: $t.home winpath: false} 'loaded, WINPATH hidden'
    assert equal $r.again [/a /mnt/c/W] 'loading again (without WINPATH) works'
  }
}

def "test env exec runs a closure with the variables" []: nothing -> nothing {
  with-win {|t|
    let r = with-env {PATH: [/a] WINPATH: [/mnt/c/W]} { win env --exec {|| {path: $env.PATH profile: $env.USERPROFILE} } }
    assert equal $r {path: [/a /mnt/c/W] profile: $t.home} 'the closure sees the windows environment'
    assert equal ($env.PATH | first) $t.stubs 'the caller environment is untouched'
  }
}

# ——— win home / win path ——————————————————————————————————————————————————————

def "test home returns USERPROFILE with joined segments" []: nothing -> nothing {
  with-win {|t|
    assert equal (win home) $t.home 'posix by default'
    assert equal (win home --join [Desktop a.txt]) ($t.home | path join Desktop a.txt) 'joined'
    assert equal (win home --posix=false) 'C:/Users/me' 'windows form'
  }
}

def "test home cd changes into USERPROFILE" []: nothing -> nothing {
  with-win {|t|
    win home --cd
    assert equal $env.PWD $t.home 'cd'
    let err = try { win home --cd --join [missing]; null } catch {|e| $e }
    assert str contains $err.msg 'resolved path is not a valid directory' 'missing directory'
    assert equal $err.details?.code? windows::win-home::not_found 'the code'
    assert ($err.details?.inner? | is-not-empty) 'the cd error is the inner error'
  }
}

def "test home edit opens USERPROFILE in EDITOR" []: nothing -> nothing {
  with-win {|t|
    let out: path = $t.ctx.code | path join edited
    stub $t.stubs editor $"echo \"$*\" > '($out)'" | ignore
    with-env {EDITOR: editor} { win home --edit --join [notes.md] }
    assert equal (open $out | str trim) ($t.home | path join notes.md) 'EDITOR receives the path'
  }
}

def "test path builds under the system drive or the home" []: nothing -> nothing {
  with-win {|t|
    assert equal (win path) /mnt/c 'system drive'
    assert equal (win path --join [Windows System32]) /mnt/c/Windows/System32 'joined'
    assert equal (win path --user --join [Desktop]) ($t.home | path join Desktop) 'home'
    assert equal (win path --user --posix=false) 'C:/Users/me' 'windows form'
  }
}

def "test path cd changes into the resolved directory" []: nothing -> nothing {
  with-win {|t|
    win path --user --cd
    assert equal $env.PWD $t.home 'cd'
    let err = try { win path --user --cd --join [missing]; null } catch {|e| $e }
    assert equal $err.details?.code? windows::win-path::not_found 'missing directory'
  }
}

def "test path uses the piped path as its base" []: nothing -> nothing {
  with-win {|t|
    assert equal ('/mnt/d' | win path --join [x]) /mnt/d/x 'the input is the base path'
    assert equal ('/mnt/d' | win path --user) /mnt/d '--user applies only without input'
    assert equal ('C:\Tools' | win path --join [x]) ($t.mnt | path join c Tools x) 'a Windows base comes back as a POSIX path'
    $t.home | win path --cd --join [..]
    assert equal $env.PWD ($t.mnt | path join c Users) 'cd into the joined input'
  }
}

def "test powershell aliases point at the windows executables" []: nothing -> nothing {
  let aliases: record = scope aliases | where name in [pwsh powershell] | select $.name $.expansion | transpose --as-record --header-row
  assert equal $aliases.pwsh /mnt/c/progra~1/PowerShell/7/pwsh.exe 'PowerShell 7'
  assert equal $aliases.powershell /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe 'Windows PowerShell'
}
