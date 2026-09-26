#!/usr/bin/env nu
# nu-lint-ignore-file: missing_output_type

# Tests for the `proj` module.
#
# Every case runs against a throwaway workspace in a fresh `nu` subprocess, because
# `use proj` scans on load and `std-rfc/kv` resolves its database path at startup.
# Your real registry and workspace are never touched.
#
# Usage:
#   nu tests.nu            # run every case
#   nu tests.nu prune      # run cases whose name matches a regex

use std/assert

const MOD: path = path self .

# ——— fixture ——————————————————————————————————————————————————————————————————

# Build an isolated workspace:
#   src/alpha  git, ssh remote        -> repo zaynram/alpha,       host github
#   src/beta   git, no remote, user   -> repo 'Test User/beta',    host null
#   src/gamma  git, https remote      -> repo some-org/gamma.lib,  host gitlab
#   dev/tools  git, no remote/user    -> repo null,                vcs git
#   txt/notes, ext/vend               -> not under version control
#   src/.hidden, src/link (symlink)   -> must be ignored
def fixture []: nothing -> record<root: path, work: path, data: path> {
  let root: path = mktemp --directory --tmpdir proj-test.XXXXXX
  let work: path = $root | path join work
  let data: path = $root | path join data
  mkdir ($data | path join nushell)
  [src/alpha src/beta src/gamma src/.hidden dev/tools txt/notes ext/vend]
  | each {|d| mkdir ($work | path join $d) }
  | ignore
  git-init ($work | path join src/alpha) --remote 'git@github.com:zaynram/alpha.git'
  git-init ($work | path join src/beta) --user 'Test User'
  git-init ($work | path join src/gamma) --remote 'https://gitlab.example.io/some-org/gamma.lib'
  git-init ($work | path join dev/tools)
  ^ln -s ($work | path join src/alpha) ($work | path join src/link)
  {root: $root, work: $work, data: $data}
}

def git-init [dir: path, --remote: string, --user: string]: nothing -> nothing {
  ^git -C $dir init --quiet
  if $remote != null { ^git -C $dir remote add origin $remote }
  if $user != null { ^git -C $dir config user.name $user }
}

# Run `code` after `use proj` in a clean subprocess; return its value.
# The value is read from the last stdout line, so `print` output above it is ignored
# unless `--printed` asks for those lines instead.
def in-proj [fx: record, code: string, --printed]: nothing -> any {
  let vars: record = {
    XDG_DATA_HOME: $fx.data
    WORK: $fx.work
    GIT_CONFIG_GLOBAL: '/dev/null' # no global user.name leaking into results
    GIT_CONFIG_NOSYSTEM: '1'
  }
  let res = with-env $vars {
    ^$nu.current-exe --no-config-file --commands $"use ($MOD)\n($code) | to nuon --serialize" | complete
  }
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

def cases []: nothing -> list<record<name: string, run: closure>> {[
  {name: 'load: auto-scan registers every kind', run: {|fx|
    let meta = in-proj $fx 'proj meta'
    assert equal $meta.total_count 6
    assert equal [$meta.src_count $meta.txt_count $meta.dev_count $meta.ext_count] [3 1 1 1]
  }}

  {name: 'scan: --reset returns the scan record', run: {|fx|
    let r = in-proj $fx 'proj scan --reset'
    assert equal ($r | columns) [found added start end elapsed]
    assert equal [$r.found $r.added] [6 6]
  }}

  {name: 'scan: --force with nothing new counts all, adds none', run: {|fx|
    let r = in-proj $fx 'proj scan --force'
    assert equal [$r.found $r.added] [6 0]
  }}

  {name: 'scan: --force picks up a new directory', run: {|fx|
    in-proj $fx 'null' | ignore
    mkdir ($fx.work | path join src/delta)
    let r = in-proj $fx 'proj scan --force'
    assert equal [$r.found $r.added] [7 1]
    assert ('delta' in (in-proj $fx 'proj list | get name'))
  }}

  {name: 'scan: plain scan inside the TTL returns the cached record', run: {|fx|
    assert (in-proj $fx 'let a = proj scan --reset; let b = proj scan; $a == $b')
  }}

  {name: 'scan: elapsed covers the whole scan', run: {|fx|
    let r = in-proj $fx 'let t = timeit { proj scan --reset | ignore }; {wall: $t, recorded: (proj meta last_scan).elapsed}'
    let recorded: float = $r.recorded | str replace ' ms' '' | into float
    let wall: float = ($r.wall | into int) / 1_000_000
    assert ($recorded > $wall * 0.5) $"recorded ($recorded)ms is far below wall ($wall)ms"
  }}

  {name: 'scan: hidden and symlinked directories are excluded', run: {|fx|
    let names = in-proj $fx 'proj list | get name'
    assert ('.hidden' not-in $names)
    assert ('link' not-in $names)
  }}

  {name: 'remote: ssh URL parses host and owner/name', run: {|fx|
    let p = project $fx alpha
    assert equal [$p.vcs $p.host $p.repo] [git github zaynram/alpha]
  }}

  {name: 'remote: https URL without .git keeps a dotted repo name', run: {|fx|
    let p = project $fx gamma
    assert equal [$p.host $p.repo] [gitlab some-org/gamma.lib]
  }}

  {name: 'remote: none, user.name set -> user/name', run: {|fx|
    let p = project $fx beta
    assert equal [$p.vcs $p.host $p.repo] [git null 'Test User/beta']
  }}

  {name: 'remote: none, no user.name -> repo null, still git', run: {|fx|
    let p = project $fx tools
    assert equal [$p.vcs $p.repo] [git null]
  }}

  {name: 'vcs: plain directory has no vcs', run: {|fx|
    let p = project $fx notes
    assert equal [$p.vcs $p.repo $p.host] [null null null]
  }}

  {name: 'list: --kind scopes, --long adds kind', run: {|fx|
    let short = in-proj $fx 'proj list --kind txt'
    let long = in-proj $fx 'proj list --kind txt --long'
    assert equal ($short | get name) [notes]
    assert ($short not-has 'kind')
    assert equal ($long | get kind) [txt]
  }}

  {name: 'aliases: project_aliases renames on intake', run: {|fx|
    let names = in-proj $fx 'with-env {project_aliases: {vend: vendored}} { proj scan --reset | ignore }; proj list | get name'
    assert ('vendored' in $names)
    assert ('vend' not-in $names)
  }}

  {name: 'prune: removes missing directories and fixes counts', run: {|fx|
    in-proj $fx 'null' | ignore # register everything
    rm --recursive ($fx.work | path join txt/notes)
    let printed = in-proj $fx 'proj scan --prune' --printed
    assert equal $printed ['removed 1 projects']
    let after = in-proj $fx '{total: (proj meta total_count), listed: (proj list | length), txt: (proj meta txt_count)}'
    assert equal $after {total: 5, listed: 5, txt: 0}
  }}

  {name: 'prune: nothing missing removes nothing', run: {|fx|
    assert equal (in-proj $fx 'proj scan --prune' --printed) ['removed 0 projects']
  }}

  {name: 'prune: missing metadata raises a helpful error', run: {|fx|
    let msg = in-proj $fx 'use std-rfc/kv *; kv drop --universal --table=proj total_count | ignore; try { proj scan --prune; "no error" } catch {|e| $e.msg }'
    assert equal $msg 'no metadata found'
  }}

  {name: 'reset: clears stale metadata and removed projects', run: {|fx|
    in-proj $fx 'use std-rfc/kv *; kv set --universal --table=proj stale-key 1' | ignore
    rm --recursive ($fx.work | path join ext/vend)
    let r = in-proj $fx 'use std-rfc/kv *; proj scan --reset | ignore; {stale: (kv get --universal --table=proj stale-key), names: (proj list | get name)}'
    assert equal $r.stale null
    assert ('vend' not-in $r.names)
  }}

  {name: 'main: unique match changes directory', run: {|fx|
    assert equal (in-proj $fx 'proj alph; $env.PWD') ($fx.work | path join src/alpha)
  }}

  {name: 'main: --kind narrows the query', run: {|fx|
    assert equal (in-proj $fx 'proj --kind txt note; $env.PWD') ($fx.work | path join txt/notes)
  }}

  {name: 'main: no match raises an error naming the query', run: {|fx|
    let msg = in-proj $fx 'try { proj zzz; "no error" } catch {|e| $e.msg }'
    assert equal $msg "no project matches 'zzz'"
  }}

  {name: 'load: works without the caller importing std/dirs', run: {|fx|
    assert equal (in-proj $fx '$env.DIRS_LIST? | describe') 'list<string>'
  }}

  {name: 'load: keeps an existing directory stack', run: {|fx|
    let r = in-proj $fx $"use std/dirs; dirs add /tmp; let before = $env.DIRS_LIST | length; use ($MOD); {before: $before, after: \($env.DIRS_LIST | length\)}"
    assert equal $r.before $r.after
  }}

  {name: 'main: already in the project does not push the stack', run: {|fx|
    let target: path = $fx.work | path join src/alpha
    let r = in-proj $fx $"cd '($target)'; let before = $env.DIRS_LIST? | length; proj alph; {before: $before, after: \($env.DIRS_LIST? | length\)}"
    assert equal $r.before $r.after
  }}
]}

# ——— runner ———————————————————————————————————————————————————————————————————

def main [filter?: string # Regex selecting which cases to run
]: nothing -> nothing {
  let results = cases
    | where {|c| $filter == null or $c.name =~ $filter }
    | each {|c|
      let fx = fixture
      let outcome = try { do $c.run $fx; {ok: true, error: ''} } catch {|e| {ok: false, error: $e.msg} }
      rm --recursive $fx.root
      {case: $c.name, ...$outcome}
    }
  let failed = $results | where not ok
  $results | select case ok | update ok { if $in { 'pass' } else { 'FAIL' } } | print
  for f in $failed { print $"\n(ansi red)FAIL(ansi reset) ($f.case)\n  ($f.error)" }
  print $"\n($results | length) run, ($failed | length) failed"
  if ($failed | is-not-empty) { exit 1 }
}
