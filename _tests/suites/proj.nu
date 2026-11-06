# `proj` against a throwaway workspace: `test _tests/suites/proj.nu`.
#
# `use proj` scans `$env.WORK` on import and keeps its registry in universal kv, so every case builds its own
# workspace inside a `with-sandbox` directory and runs `proj` in a sandboxed child interpreter. The real
# registry and workspace are never touched.
use ../mod.nu *

# ——— fixture ——————————————————————————————————————————————————————————————————

# Build an isolated workspace under the sandbox:
#   src/alpha  git, ssh remote        -> repo zaynram/alpha,       host github
#   src/beta   git, no remote, user   -> repo 'Test User/beta',    host null
#   src/gamma  git, https remote      -> repo some-org/gamma.lib,  host gitlab
#   dev/tools  git, no remote/user    -> repo null,                vcs git
#   txt/notes, ext/vend               -> not under version control
#   src/.hidden, src/link (symlink)   -> must be ignored
def fixture [ctx: record]: nothing -> record<ctx: record, root: path, work: path> {
  let work: path = $ctx.code | path join work
  [src/alpha src/beta src/gamma src/.hidden dev/tools txt/notes ext/vend]
  | each {|d| mkdir ($work | path join $d) }
  | ignore
  git-init ($work | path join src/alpha) --remote 'git@github.com:zaynram/alpha.git'
  git-init ($work | path join src/beta) --user 'Test User'
  git-init ($work | path join src/gamma) --remote 'https://gitlab.example.io/some-org/gamma.lib'
  git-init ($work | path join dev/tools)
  ^ln -s ($work | path join src/alpha) ($work | path join src/link)
  {ctx: $ctx root: $ctx.root work: $work}
}

def git-init [dir: path, --remote: string, --user: string]: nothing -> nothing {
  ^git -C $dir init --quiet
  if $remote != null { ^git -C $dir remote add origin $remote }
  if $user != null { ^git -C $dir config user.name $user }
}

# Run a case body against a fresh workspace.
def case [body: closure]: nothing -> nothing {
  if (which git | is-empty) { skip 'git is not installed' }
  with-sandbox {|ctx| do $body (fixture $ctx) } | ignore
}

# Run `code` after `use proj` in a sandboxed child; return its value.
# The value is read from the last stdout line, so `print` output above it is ignored
# unless `--printed` asks for those lines instead.
def in-proj [fx: record, code: string, --printed]: nothing -> any {
  let vars: record = {
    WORK: $fx.work
    GIT_CONFIG_GLOBAL: '/dev/null' # no global user.name leaking into results
    GIT_CONFIG_NOSYSTEM: '1'
  }
  let res: record = sandboxed $fx.ctx $"($code) | to nuon --serialize" --prelude 'use proj' --vars $vars
  if $res.exit_code != 0 {
    error make --unspanned {msg: $"subprocess failed: ($res.stderr | str trim)"}
  }
  let out: list<string> = $res.stdout | lines
  if $printed { $out | drop } else { $out | last | from nuon }
}

def project [fx: record, name: string]: nothing -> record {
  in-proj $fx 'proj list --long' | where name == $name | first
}

# ——— cases ————————————————————————————————————————————————————————————————————

def "test load auto scan registers every kind" []: nothing -> nothing {
  case {|fx|
      let meta = in-proj $fx 'proj meta'
      assert equal $meta.total_count 6
      assert equal [$meta.src_count $meta.txt_count $meta.dev_count $meta.ext_count] [3 1 1 1]
  }
}

def "test scan reset returns the scan record" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx 'proj scan --reset'
      assert equal ($r | columns) [found added start end elapsed]
      assert equal [$r.found $r.added] [6 6]
  }
}

def "test scan force with nothing new counts all adds none" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx 'proj scan --force'
      assert equal [$r.found $r.added] [6 0]
  }
}

def "test scan force picks up a new directory" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'null' | ignore
      mkdir ($fx.work | path join src/delta)
      let r = in-proj $fx 'proj scan --force'
      assert equal [$r.found $r.added] [7 1]
      assert ('delta' in (in-proj $fx 'proj list | get name'))
  }
}

def "test scan plain scan inside the ttl returns the cached record" []: nothing -> nothing {
  case {|fx|
      assert (in-proj $fx 'let a = proj scan --reset; let b = proj scan; $a == $b')
  }
}

def "test scan elapsed covers the whole scan" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx 'let t = timeit { proj scan --reset | ignore }; {wall: $t, recorded: (proj meta last_scan).elapsed}'
      let recorded: float = $r.recorded | str replace ' ms' '' | into float
      let wall: float = ($r.wall | into int) / 1_000_000
      assert ($recorded > $wall * 0.5) $"recorded ($recorded)ms is far below wall ($wall)ms"
  }
}

def "test scan hidden and symlinked directories are excluded" []: nothing -> nothing {
  case {|fx|
      let names = in-proj $fx 'proj list | get name'
      assert ('.hidden' not-in $names)
      assert ('link' not-in $names)
  }
}

def "test remote ssh url parses host and owner name" []: nothing -> nothing {
  case {|fx|
      let p = project $fx alpha
      assert equal [$p.vcs $p.host $p.repo] [git github zaynram/alpha]
  }
}

def "test remote https url without git keeps a dotted repo name" []: nothing -> nothing {
  case {|fx|
      let p = project $fx gamma
      assert equal [$p.host $p.repo] [gitlab some-org/gamma.lib]
  }
}

def "test remote none user name set to user name" []: nothing -> nothing {
  case {|fx|
      let p = project $fx beta
      assert equal [$p.vcs $p.host $p.repo] [git null 'Test User/beta']
  }
}

def "test remote none no user name to repo null still git" []: nothing -> nothing {
  case {|fx|
      let p = project $fx tools
      assert equal [$p.vcs $p.repo] [git null]
  }
}

def "test vcs plain directory has no vcs" []: nothing -> nothing {
  case {|fx|
      let p = project $fx notes
      assert equal [$p.vcs $p.repo $p.host] [null null null]
  }
}

def "test list kind scopes long adds kind" []: nothing -> nothing {
  case {|fx|
      let short = in-proj $fx 'proj list --kind txt'
      let long = in-proj $fx 'proj list --kind txt --long'
      assert equal ($short | get name) [notes]
      assert ($short not-has 'kind')
      assert equal ($long | get kind) [txt]
  }
}

def "test aliases project aliases renames on intake" []: nothing -> nothing {
  case {|fx|
      let names = in-proj $fx 'with-env {project_aliases: {vend: vendored}} { proj scan --reset | ignore }; proj list | get name'
      assert ('vendored' in $names)
      assert ('vend' not-in $names)
  }
}

def "test prune removes missing directories and fixes counts" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'null' | ignore # register everything
      rm --recursive ($fx.work | path join txt/notes)
      let printed = in-proj $fx 'proj scan --prune' --printed
      assert equal $printed ['removed 1 projects']
      let after = in-proj $fx '{total: (proj meta total_count), listed: (proj list | length), txt: (proj meta txt_count)}'
      assert equal $after {total: 5, listed: 5, txt: 0}
  }
}

def "test prune nothing missing removes nothing" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx 'proj scan --prune' --printed) ['removed 0 projects']
  }
}

def "test prune missing metadata raises a helpful error" []: nothing -> nothing {
  case {|fx|
      let msg = in-proj $fx 'use std-rfc/kv *; kv drop --universal --table=proj total_count | ignore; try { proj scan --prune; "no error" } catch {|e| $e.msg }'
      assert equal $msg 'no metadata found'
  }
}

def "test reset clears stale metadata and removed projects" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'use std-rfc/kv *; kv set --universal --table=proj stale-key 1' | ignore
      rm --recursive ($fx.work | path join ext/vend)
      let r = in-proj $fx 'use std-rfc/kv *; proj scan --reset | ignore; {stale: (kv get --universal --table=proj stale-key), names: (proj list | get name)}'
      assert equal $r.stale null
      assert ('vend' not-in $r.names)
  }
}

def "test main unique match changes directory" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx 'proj alph; $env.PWD') ($fx.work | path join src/alpha)
  }
}

def "test main kind narrows the query" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx 'proj --kind txt note; $env.PWD') ($fx.work | path join txt/notes)
  }
}

def "test main no match raises an error naming the query" []: nothing -> nothing {
  case {|fx|
      let msg = in-proj $fx 'try { proj zzz; "no error" } catch {|e| $e.msg }'
      assert equal $msg "no project matches 'zzz'"
  }
}

def "test load works without the caller importing std dirs" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx '$env.DIRS_LIST? | describe') 'list<string>'
  }
}

def "test load keeps an existing directory stack" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx $"use std/dirs; dirs add /tmp; let before = $env.DIRS_LIST | length; use proj; {before: $before, after: \($env.DIRS_LIST | length\)}"
      assert equal $r.before $r.after
  }
}

def "test main already in the project does not push the stack" []: nothing -> nothing {
  case {|fx|
      let target: path = $fx.work | path join src/alpha
      let r = in-proj $fx $"cd '($target)'; let before = $env.DIRS_LIST? | length; proj alph; {before: $before, after: \($env.DIRS_LIST? | length\)}"
      assert equal $r.before $r.after
  }
}
