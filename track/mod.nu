# Automatic Timewarrior tracking of the repository and branch in focus, tagged with the matched Todoist task.
#
# `use track` registers two hooks: `track::sync` (pre_execution) and `track::focus` (env_change.PWD). Each shell
# keeps its own focus in `$env.TRACK`; the only state shared by every shell is the `disabled` switch in
# `kv --universal --table=track`, set when tracking fails and cleared by the next focus refresh.

use std-rfc/kv [ "kv set" "kv get" "kv drop" ]

use time
use todo
# ——— constants ————————————————————————————————————————————————————————————————

# Matches are cached per shell for this long before `todo find` runs again for the same branch.
const MATCH_TTL: duration = 1hr

# ——— aliases ——————————————————————————————————————————————————————————————————

alias get-disabled = kv get --universal --table=track disabled
alias set-disabled = kv set --universal --table=track disabled true
alias drop-disabled = kv drop --universal --table=track disabled

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  use hook [ add is-enabled ]
  add --dedupe pre_execution {
    name: 'track::sync'
    condition: {|| is-enabled --name=track::sync }
    code: {|| sync }
  }
  add --dedupe env_change.PWD {
    name: 'track::focus'
    condition: {|_ pwd| (is-enabled --name=track::focus) and not ($pwd | is-within $env.TRACK?.root?) }
    code: {|| focus --refresh | ignore }
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# This shell's focus, cached in `$env.TRACK`.
#
# Inside a repository: `{root repo head branch task tags matches}`. Outside one the focus is `{root: null}`
# (plus the `matches` cache). `head` is the repository's HEAD file, which `sync` reads to notice checkouts
# without a subprocess. `task` is the matched Todoist task content, or null; `matches` caches each
# `<repo>@<branch>` match for an hour. A refresh also re-enables tracking after an error (see `sync`).
@category productivity
export def --env focus [
  --refresh (-r) # Recompute from the current directory instead of returning the cache
]: nothing -> oneof<nothing, record> {
  if not $refresh { return $env.TRACK? }
  drop-disabled | ignore
  let matches: record = $env.TRACK?.matches? | default {}
  let res: record = do --ignore-errors { ^git rev-parse --show-toplevel --absolute-git-dir } | complete
  $env.TRACK = if $res.exit_code != 0 { {root: null matches: $matches} } else {
    let paths: list<string> = $res.stdout | lines
    let repo: string = $paths | first | path basename
    let head: path = $paths | last | path join HEAD
    let branch: string = read-branch $head
    let key: string = $'($repo)@($branch)'
    let task: oneof<nothing, string> = match ($matches | get --optional $key) {
      {at: $a task: $t} if (date now) - $a < $MATCH_TTL => $t
      _ => (try { todo find $branch --project=$repo | get $.content? })
    }
    {
      root: ($paths | first)
      repo: $repo
      head: $head
      branch: $branch
      task: $task
      tags: [$'#($repo)' ($task | default $branch)]
      matches: ($matches | upsert $key {task: $task at: (date now)})
    }
  }
  $env.TRACK
}

# Align the open Timewarrior interval with this shell's focus; the `track::sync` pre_execution hook body.
#
# 1. The focus is refreshed when there is none yet, or when the HEAD file names another branch (a checkout).
# 2. Outside a repository, or while tracking is disabled, nothing else happens.
# 3. If the activity stamp is older than `--idle`, the open interval ends at the stamp.
# 4. If the open interval's tags differ from the focus tags, a new interval starts.
# 5. The stamp is touched.
# An error prints one line and disables tracking in every shell until the next focus refresh (a directory
# change out of the repository, a checkout, or a new shell).
@category productivity
export def --env sync [
  --idle: duration = 30min # Gap after which the open interval counts as abandoned
]: nothing -> nothing {
  if ($env.TRACK? | is-stale-focus) { focus --refresh | ignore }
  if $env.TRACK.root == null or (get-disabled | default false) { return }
  try {
    let tags: list = $env.TRACK.tags
    let stamp: path = time db | path join track.stamp
    let last: oneof<nothing, datetime> = try { ls $stamp | get $.0?.modified }
    let abandoned: bool = $last != null and (date now) - $last > $idle
    # ponytail: one `timew` call per command keeps Timewarrior the only state; cache if it drags
    time active
    | if $in != null and $abandoned and $in.start < $last { time stop --at=$last | ignore } else { }
    | if $in == null or ($in.tags | sort) != ($tags | sort) { time start ...$tags | ignore }
    $stamp | path dirname | mkdir $in
    touch $stamp
  } catch {|err|
    print --stderr $"track: disabled until PWD changes \(reason: ($err.msg))"
    set-disabled | ignore
  }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Whether the cached focus must be recomputed: none yet, or its HEAD file names another branch.
def is-stale-focus []: oneof<nothing, record> -> bool {
  let focus: oneof<nothing, record> = $in
  if $focus == null or $focus not-has root { return true }
  $focus.root != null and (try { read-branch $focus.head } catch { null }) != $focus.branch
}

# Whether the input path is `root` or inside it (false when `root` is null).
# nu-lint-ignore: unused_helper_functions
def is-within [root: oneof<nothing, path>]: path -> bool {
  let p: path = $in
  $root != null and ($p == $root or ($p | str starts-with ($root | path join '')))
}

# Branch name from a HEAD file, or the short commit hash when detached.
def read-branch [head: path]: nothing -> string {
  open --raw $head
  | str trim
  | if $in starts-with 'ref: refs/heads/' {
    str replace 'ref: refs/heads/' ''
  } else {
    str substring 0..<8
  }
}
