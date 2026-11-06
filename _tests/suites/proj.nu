# `proj` against a throwaway workspace: `test _tests/suites/proj.nu`.
#
# `proj` keeps its registry (one snapshot) in universal kv and scans `$env.WORK` — in a background job when an
# interactive shell imports it, synchronously when a non-interactive reader finds no snapshot — so every case builds
# its own workspace inside a `with-sandbox` directory and runs `proj` in a sandboxed child interpreter. The real
# registry and workspace are never touched. The sandboxed children are not interactive: the import-time job is
# exercised through interactive grandchildren (`in-interactive`).
# nu-lint-ignore-file: missing_output_type
# (`in-proj` returns whatever the child produced: a nuon value, or its printed lines)
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
  need-posix # the fixture's symlink
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

def "test load a reader builds the snapshot when there is none" []: nothing -> nothing {
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
      let r = in-proj $fx 'proj scan --force | ignore; proj scan --force'
      assert equal [$r.found $r.added] [6 0]
  }
}

def "test scan force picks up a new directory" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
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
      in-proj $fx 'proj scan --force' | ignore # register everything
      rm --recursive ($fx.work | path join txt/notes)
      let printed = in-proj $fx 'proj scan --prune' --printed
      assert equal $printed ['removed 1 projects']
      let after = in-proj $fx '{total: (proj meta total_count), listed: (proj list | length), txt: (proj meta txt_count)}'
      assert equal $after {total: 5, listed: 5, txt: 0}
  }
}

def "test prune nothing missing removes nothing" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx 'proj scan --force | ignore; proj scan --prune' --printed) ['removed 0 projects']
  }
}

# The error `code` raises in the child, as `{msg code help}` (`in-proj` fails when it raises nothing).
def caught-in-proj [fx: record, code: string]: nothing -> record {
  in-proj $fx $"try { ($code); error make --unspanned {msg: 'sbproj: nothing was raised'} } catch {|e| {msg: $e.msg code: $e.details?.code? help: $e.details?.help?} }"
}

def "test prune missing metadata raises a helpful error" []: nothing -> nothing {
  case {|fx|
      let err = caught-in-proj $fx 'use std-rfc/kv *; kv drop --universal --table=proj snapshot | ignore; proj scan --prune'
      assert equal $err.msg 'no metadata found' 'the message'
      assert equal $err.code 'proj::prune-missing-dirs::not_found' 'the code'
      assert equal $err.help 'run a scan first' 'the remedy is the advice'
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
      let err = caught-in-proj $fx 'proj zzz'
      assert equal $err.msg "no project matches 'zzz'" 'the message'
      assert equal $err.code 'proj::not_found' 'the code (main has no command segment)'
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

# ——— without a workspace ——————————————————————————————————————————————————————

# Run `code` after `use proj` in a sandboxed child without WORK; return its value.
def in-bare [ctx: record, code: string]: nothing -> oneof<nothing, bool, int, string, list, record> {
  sandboxed $ctx $"($code) | to nuon --serialize" --prelude 'use proj' --pipe
}

def "test load without work does not fail" []: nothing -> nothing {
  with-sandbox {|ctx|
    assert equal (in-bare $ctx '{meta: (proj meta), list: (proj list)}') {meta: {} list: []} 'nothing scanned, nothing listed'
  }
}

def "test scan without work names the variable" []: nothing -> nothing {
  with-sandbox {|ctx|
    let err = in-bare $ctx 'try { proj scan; null } catch {|e| {msg: $e.msg code: $e.details?.code? help: $e.details?.help?} }'
    assert equal $err.msg 'WORK is not set' 'the message names WORK'
    assert equal $err.code 'proj::workspace::missing_dependency' 'the derived code: the missing configuration'
    assert ($err.help has '$env.WORK') 'the advice says what to set'
  }
}

def "test kind without work names the variable" []: nothing -> nothing {
  with-sandbox {|ctx|
    assert equal (in-bare $ctx 'try { proj kind src; null } catch {|e| $e.msg }') 'WORK is not set' 'one kind'
    assert equal (in-bare $ctx 'try { proj kind --all; null } catch {|e| $e.msg }') 'WORK is not set' 'all kinds'
  }
}

def "test main scan without work names the variable" []: nothing -> nothing {
  with-sandbox {|ctx|
    assert equal (in-bare $ctx 'try { proj --scan x; null } catch {|e| $e.msg }') 'WORK is not set' 'proj --scan'
  }
}

def "test empty work counts as unset" []: nothing -> nothing {
  with-sandbox {|ctx|
    let r = sandboxed $ctx 'try { proj scan; null } catch {|e| $e.msg } | to nuon' --prelude 'use proj' --vars {WORK: ''} --pipe
    assert equal $r 'WORK is not set' 'an empty WORK is no workspace'
  }
}

# ——— scan options ——————————————————————————————————————————————————————————————

def "test scan kinds limits the scan and keeps the other counts" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx 'proj scan --force | ignore; let r = proj scan --reset --kinds [src]; {r: $r, meta: (proj meta | select src_count txt_count dev_count ext_count total_count)}'
      assert equal [$r.r.found $r.r.added] [3 3] 'only src is scanned'
      assert equal $r.meta {src_count: 3 txt_count: 1 dev_count: 1 ext_count: 1 total_count: 6} 'other kinds keep their counts, the total covers all (P7)'
  }
}

def "test scan kinds reset drops only that kind" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      rm --recursive ($fx.work | path join src/beta)
      let r = in-proj $fx 'proj scan --reset --kinds [src] | ignore; {names: (proj list | get name | sort), total: (proj meta total_count)}'
      assert equal $r.names [alpha gamma notes tools vend] 'src is rebuilt, the rest is kept'
      assert equal $r.total 5 'the total is recomputed'
  }
}

def "test scan rejects an unknown kind" []: nothing -> nothing {
  case {|fx|
      let err = caught-in-proj $fx 'proj scan --force --kinds [src zz]'
      assert equal $err.msg "unknown kind: 'zz'" 'named in the error'
      assert equal $err.code 'proj::scan::invalid_argument' 'the code'
      assert ($err.help =~ 'src, txt, dev, ext') $'the advice lists the kinds: ($err.help)'
  }
}

def "test scan validates the kinds inside the ttl" []: nothing -> nothing {
  case {|fx|
      let err = caught-in-proj $fx 'proj scan --force | ignore; proj scan --kinds [zz]'
      assert equal $err.code 'proj::scan::invalid_argument' 'a fresh snapshot does not skip the check'
      assert equal $err.msg "unknown kind: 'zz'" 'named in the error'
  }
}

def "test scan needs the workspace inside the ttl" []: nothing -> nothing {
  case {|fx|
      let err = caught-in-proj $fx 'proj scan --force | ignore; hide-env WORK; proj scan'
      assert equal $err.msg 'WORK is not set' 'a fresh snapshot does not stand in for the workspace'
      assert equal $err.code 'proj::workspace::missing_dependency' 'the derived code'
  }
}

def "test scan of no kinds finds nothing" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx 'proj scan --force --kinds []'
      assert equal [$r.found $r.added] [0 0] 'zero totals'
  }
}

def "test scan project exclude globs per kind" []: nothing -> nothing {
  case {|fx|
      let names = in-proj $fx "with-env {project_exclude: {src: ['**/be*']}} { proj scan --reset | ignore }; proj list --kind src | get name | sort"
      assert equal $names [alpha gamma] 'beta is excluded'
  }
}

# ——— aliases ——————————————————————————————————————————————————————————————————

def "test aliases by absolute path" []: nothing -> nothing {
  case {|fx|
      let path: path = $fx.work | path join ext/vend
      let names = in-proj $fx $"with-env {project_aliases: {($path | to nuon): vendored}} { proj scan --reset | ignore }; proj list | get name"
      assert ('vendored' in $names) 'renamed by path'
      assert ('vend' not-in $names) 'the directory name is gone'
  }
}

def "test aliases apply to registered projects on rescan" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore # registers vend under its directory name
      let names = in-proj $fx 'with-env {project_aliases: {vend: vendored}} { proj scan --force | ignore }; proj list | get name'
      assert ('vendored' in $names) 'renamed by directory name (P4), before the scan returns (P5)'
      assert ('vend' not-in $names) 'no duplicate left behind'
  }
}

# ——— remotes ——————————————————————————————————————————————————————————————————

def "test remote url forms" []: nothing -> nothing {
  case {|fx|
      let remotes: record = {
        port: 'ssh://git@github.com:2222/owner/port.git'
        scheme: 'ssh://git@github.com/owner/scheme.git'
        slash: 'https://user@gitlab.com/owner/slash/'
        numeric: 'git@host.example:1234/numeric.git'
      }
      $remotes | items {|name url|
        let dir: path = $fx.work | path join src $name
        mkdir $dir
        git-init $dir --remote $url
      } | ignore
      let rows = in-proj $fx 'proj scan --force | ignore; proj list --kind src | select name host repo'
      let got: record = $rows | where $remotes has $it.name | each {|r| {($r.name): [$r.host $r.repo]} } | into record
      assert equal $got.port [github owner/port] 'ssh with a port'
      assert equal $got.scheme [github owner/scheme] 'ssh scheme'
      assert equal $got.slash [gitlab owner/slash] 'https with a user and a trailing slash'
      assert equal $got.numeric [host 1234/numeric] 'scp-style with a numeric owner'
  }
}

# ——— kind, meta, list —————————————————————————————————————————————————————————

def "test kind summarizes one kind" []: nothing -> nothing {
  case {|fx|
      let k = in-proj $fx 'proj kind txt'
      assert equal ($k | reject projects) {name: txt root: ($fx.work | path join txt) description: 'projects containing mostly prose'} 'name, root and description'
      assert equal ($k.projects | get name) [notes] 'its projects'
      assert equal ($k.projects | get kind) [txt] 'with their kind'
  }
}

def "test kind all lists every kind" []: nothing -> nothing {
  case {|fx|
      let all = in-proj $fx 'proj kind --all'
      assert equal ($all | get name) [src txt dev ext] 'every kind'
      assert equal ($all | columns) [name description root projects] 'the summary columns'
      assert equal ($all | where name == dev | get $.0.projects | get name) [tools] 'with its projects'
  }
}

def "test kind errors" []: nothing -> nothing {
  case {|fx|
      let unknown = caught-in-proj $fx 'proj kind zz'
      assert equal $unknown.msg "unknown kind: 'zz'" 'unknown kind'
      assert equal $unknown.code 'proj::kind::invalid_argument' 'the code'
      let none = caught-in-proj $fx 'proj kind'
      assert equal $none.msg 'a kind must be provided without `--all`' 'no kind'
      assert equal $none.code 'proj::kind::invalid_argument' 'the same code'
  }
}

def "test meta by key" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx 'proj meta src_count') 3 'one value'
      assert equal (in-proj $fx 'proj meta nope') null 'a missing key is null'
      assert equal (in-proj $fx 'proj meta last_scan | columns') [found added start end elapsed] 'the last scan'
  }
}

def "test list of an unknown kind is empty" []: nothing -> nothing {
  case {|fx|
      assert equal (in-proj $fx 'proj list --kind zz') [] 'no rows'
  }
}

# ——— test fixture —————————————————————————————————————————————————————————————

def "test fixture registers and removes test projects" []: nothing -> nothing {
  case {|fx|
      let code = "use proj [test]; [{name: fake path: /nowhere repo: null vcs: null host: null}] | test before; let during = proj list --long | where kind == test | get name; test after; {during: $during, after: (proj list --long | where kind == test | get name), env: ($env.project_testing? == null)}"
      let r = in-proj $fx $code
      assert equal $r.during [fake] 'listed while active'
      assert equal $r.after [] 'removed afterwards'
      assert $r.env 'the fixture variable is hidden'
  }
}

def "test fixture after without before raises" []: nothing -> nothing {
  case {|fx|
      let err = caught-in-proj $fx 'use proj [test]; test after'
      assert equal $err.msg "test fixture is inactive for kind 'test'" 'inactive fixture'
      # the code names the raising def; the `test` submodule it lives in is not a segment
      assert equal $err.code 'proj::after::conflict' 'the code'
  }
}

# ——— main ——————————————————————————————————————————————————————————————————————

def "test main exec runs the closure from the project root" []: nothing -> nothing {
  case {|fx|
      let r = in-proj $fx 'let at = proj alph --exec {|| $env.PWD }; {at: $at, pwd: $env.PWD}'
      assert equal $r.at ($fx.work | path join src/alpha) 'the closure runs in the project (P3)'
      assert ($r.pwd != $r.at) 'the caller does not move'
  }
}

def "test main exec disables the zellij hook meanwhile" []: nothing -> nothing {
  case {|fx|
      let code = "use hook; hook add $.env_change.PWD {name: 'zellij::pwd::auto-switch' code: {|| null }}; {inside: (proj alph --exec {|| hook is-enabled --name=zellij::pwd::auto-switch }), after: (hook is-enabled --name=zellij::pwd::auto-switch)}"
      assert equal (in-proj $fx $code) {inside: false after: true} 'disabled only while the closure runs'
  }
}

def "test main scan picks up new projects first" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      mkdir ($fx.work | path join dev/fresh)
      assert equal (in-proj $fx 'proj --scan fresh; $env.PWD') ($fx.work | path join dev/fresh) 'found and entered'
  }
}

# ——— snapshot and hydration ———————————————————————————————————————————————————

# Run `code` after `use proj` in an INTERACTIVE grandchild (so the import-time hydration job runs); return
# {value, stderr}. `--pre` runs before `use proj` (the import is a runtime statement, so a mark it sets is seen).
def in-interactive [fx: record, code: string, --pre: string = '', --vars: record = {}]: nothing -> record<value: any, stderr: string> {
  let program: string = $"($pre); use proj; ($code) | to nuon --serialize"
  # The same throwaway HOME/XDG tree as `sandboxed` gives the non-interactive children: one registry per case.
  let sandbox: record = {
    HOME: $fx.ctx.home XDG_CONFIG_HOME: $fx.ctx.config XDG_DATA_HOME: $fx.ctx.data
    XDG_CACHE_HOME: $fx.ctx.cache XDG_STATE_HOME: $fx.ctx.state
  }
  let res: record = with-env ($sandbox | merge {WORK: $fx.work GIT_CONFIG_GLOBAL: '/dev/null' GIT_CONFIG_NOSYSTEM: '1'} | merge $vars) {
    '' | ^$nu.current-exe --no-config-file --interactive --include-path $ROOT -c $program | complete
  }
  if $res.exit_code != 0 { error make --unspanned {msg: $"interactive grandchild failed: ($res.stderr | str trim)"} }
  {value: ($res.stdout | lines | last | from nuon) stderr: $res.stderr}
}

# Wait (up to 10 s) for the hydration job of the running shell to finish.
const AWAIT: string = 'for _ in 1..100 { if (job list | is-empty) { break }; sleep 100ms }'

def "test snapshot is the only key the registry holds" []: nothing -> nothing {
  case {|fx|
      let keys = in-proj $fx 'proj scan --force | ignore; use std-rfc/kv *; kv list --universal --table=proj | get key'
      assert equal $keys [snapshot] 'one atomic value'
  }
}

def "test snapshot a stale one is served as it is by a non-interactive shell" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      rm --recursive ($fx.work | path join txt/notes)
      mkdir ($fx.work | path join src/delta)
      assert equal (in-proj $fx 'proj list | get name | sort') [alpha beta gamma notes tools vend] 'no refresh: the snapshot as stored'
      assert equal (in-proj $fx 'proj scan --force | ignore; proj list | get name | sort') [alpha beta delta gamma tools vend] 'a scan drops the missing and adds the new'
  }
}

def "test hydration an interactive import refreshes in the background" []: nothing -> nothing {
  case {|fx|
      let r = in-interactive $fx $"let spawned = job list | get description; ($AWAIT); {spawned: $spawned, after: \(job list | length\), meta: \(proj meta | select total_count hydrating\)}"
      assert equal $r.value.spawned ['proj: scanning the workspace'] 'one job, described'
      assert equal $r.value.after 0 'it finished'
      assert equal $r.value.meta {total_count: 6 hydrating: false} 'and wrote the snapshot'
      assert equal (in-proj $fx 'proj meta hydrating') false 'no job elsewhere'
  }
}

def "test hydration a fresh snapshot spawns nothing" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      let r = in-interactive $fx 'job list | length'
      assert equal $r.value 0 'nothing to refresh'
  }
}

def "test hydration a changed workspace is refreshed" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      mkdir ($fx.work | path join dev/fresh)
      let r = in-interactive $fx $"let n = job list | length; ($AWAIT); {jobs: $n, names: \(proj list --kind dev | get name | sort\)}"
      assert equal $r.value {jobs: 1 names: [fresh tools]} 'the kind directory changed, so a job ran and found it'
  }
}

def "test hydration a fresh mark prevents a duplicate job" []: nothing -> nothing {
  case {|fx|
      let r = in-interactive $fx 'job list | length' --pre 'use std-rfc/kv *; kv set --universal --table=proj hydrating (date now) | ignore'
      assert equal $r.value 0 'another shell is already at it'
  }
}

def "test hydration a failing job keeps the previous snapshot and warns once" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      mkdir ($fx.work | path join dev/fresh)
      # a string where a record of globs is expected makes the scan raise inside the job
      let r = in-interactive $fx $"($AWAIT); {names: \(proj list --kind dev | get name\), keys: \(use std-rfc/kv *; kv list --universal --table=proj | get key\)}" --vars {project_exclude: oops}
      assert equal $r.value.names [tools] 'the snapshot is the old one'
      assert equal $r.value.keys [snapshot] 'the mark is cleared'
      assert equal ($r.stderr | lines | where $it =~ 'proj: the background scan failed' | length) 1 'one warning'
  }
}

def "test prune keeps the stamp and a plain scan then sees the new directory" []: nothing -> nothing {
  case {|fx|
      let code = 'proj scan --force | ignore; let before = (proj meta).stamp.fingerprint.src; mkdir ($env.WORK | path join src delta); proj scan --prune | ignore; let kept = (proj meta).stamp.fingerprint.src == $before; proj scan | ignore; {kept: $kept, names: (proj list --kind src | get name | sort)}'
      let r = in-proj $fx $code
      assert $r.kept 'prune inspects nothing, so it leaves the fingerprint alone'
      assert ('delta' in $r.names) 'a plain scan honours the fingerprint, not only the TTL'
  }
}

def "test hydration past the ttl inspects registered projects again" []: nothing -> nothing {
  case {|fx|
      in-proj $fx 'proj scan --force' | ignore
      ^git -C ($fx.work | path join dev/tools) remote add origin 'git@github.com:zaynram/tools.git'
      in-proj $fx 'use std-rfc/kv *; kv get --universal --table=proj snapshot | update stamp.at ((date now) - 2day) | kv set --universal --table=proj snapshot | ignore' | ignore
      let r = in-interactive $fx $"($AWAIT); proj list --kind dev | where name == tools | get 0.repo"
      assert equal $r.value 'zaynram/tools' 'the TTL refresh re-inspects the repository'
  }
}

def "test meta reports hydration while the first scan runs" []: nothing -> nothing {
  case {|fx|
      # a fresh mark stands for another shell's job; this shell spawns none and has no snapshot to read
      let r = in-interactive $fx 'proj meta' --pre 'use std-rfc/kv *; kv set --universal --table=proj hydrating (date now) | ignore'
      assert equal $r.value {hydrating: true} 'only the hydration state is known'
  }
}

def "test reset drops pruned_at and keeps the hydration mark" []: nothing -> nothing {
  case {|fx|
      let code = 'use std-rfc/kv *; proj scan --force | ignore; proj scan --prune | ignore; kv set --universal --table=proj hydrating (date now) | ignore; proj scan --reset | ignore; {pruned: (proj meta pruned_at), mark: (kv get --universal --table=proj hydrating | describe)}'
      assert equal (in-proj $fx $code) {pruned: null mark: datetime} 'metadata gone, the mark kept'
  }
}

def "test a failing reset scan leaves the snapshot in place" []: nothing -> nothing {
  case {|fx|
      let code = "proj scan --force | ignore; use std-rfc/kv *; kv set --universal --table=proj hydrating (date now) | ignore; let failed = try { with-env {project_exclude: {src: ['[bad']}} { proj scan --force --reset }; false } catch { true }; {failed: $failed, names: (proj list | get name | sort), mark: (kv get --universal --table=proj hydrating | describe)}"
      let r = in-proj $fx $code
      assert $r.failed 'the bad glob makes the scan raise'
      assert equal $r.names [alpha beta gamma notes tools vend] 'the previous snapshot survives'
      assert equal $r.mark datetime 'and so does the hydration mark'
  }
}
