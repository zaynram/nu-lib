# Automatic Timewarrior tracking of the repository and branch in focus, tagged with the matched Todoist task.

use ../time
use ../todo
use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]
# ——— constants ————————————————————————————————————————————————————————————————

# Matches are cached per shell for this long before `todo find` runs again for the same branch.
const MATCH_TTL: duration = 1hr

# ——— aliases ——————————————————————————————————————————————————————————————————

alias set-track = kv set --universal --table=track
alias get-track = kv get --universal --table=track
alias drop-track = kv drop --universal --table=track
alias list-track = kv list --universal --table=track

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  use hook [ add is-enabled ]
  add pre_execution { track sync }
  add env_change.PWD {
    name: 'track::focus'
    condition: {|_ pwd|
      if not (is-enabled --name=track::focus) { return false }
      let root: oneof<nothing, path> = get-track root
      $root == null or $pwd not-has $root
    }
    code: {|| track focus --refresh | ignore }
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

def track-record []: nothing -> record {
  list-track | if $in == [] { return {} } else { transpose --ignore-titles --header-row --as-record }
}

# This shell's focus, cached with `kv [set|get|drop|list] --universal --table=track`.
#
# `root` is null outside a repository. `head` is the repository's HEAD file, which `sync` reads to
# notice checkouts without a subprocess. `task` is the matched Todoist task content, or null.
@category productivity
export def focus [
  --refresh (-r) # Recompute from the current directory instead of returning the cache
]: nothing -> oneof<nothing, record> {
  if not $refresh { return (track-record) }
  do --ignore-errors { ^git rev-parse --show-toplevel --absolute-git-dir }
  | complete
  | if $in.exit_code != 0 {
    drop-track root | ignore
  } else {
    let paths: list = $in.stdout | lines
    let repo: string = $paths | first | path basename
    let head: path = $paths | last | path join HEAD
    let branch: string = read-branch $head
    let key: string = $'($repo)@($branch)'
    let matches: record = get-track matches | default {}
    let task: oneof<nothing, string> = match ($matches | get --optional $key) {
      {at: $a task: $t} if (date now) - $a < $MATCH_TTL => $t
      _ => (try { todo find $branch --project=$repo | get $.content? })
    }
    set-track root $paths.0
    set-track repo $repo
    set-track head $head
    set-track branch $branch
    set-track task $task
    set-track tags [$'#($repo)' ($task | default $branch)]
    set-track matches ($matches | upsert $key {task: $task at: (date now)})
  }
  return (track-record)
}

# Align the open Timewarrior interval with this shell's focus; the pre_execution hook body.
#
# 1. If the activity stamp is older than `--idle`, the open interval ends at the stamp.
# 2. If the open interval's tags differ from the focus tags, a new interval starts.
# 3. The stamp is touched. Outside a repository nothing happens; after an error the shell's
#    tracking stays off until the next `focus --refresh`.
@category productivity
export def sync [
  --idle: duration = 30min # Gap after which the open interval counts as abandoned
]: nothing -> nothing {
  let cached: oneof<nothing, record> = (track-record)
  if $cached == null or ($cached.root != null and (read-branch $cached.head) != $cached.branch) { focus --refresh }
  if (get-track root) == null or (get-track disabled | default false) { return }
  try {
    let tags: list = get-track tags | default []
    let stamp: path = time db | path join track.stamp
    let last: oneof<nothing, datetime> = try { ls $stamp | get $.0?.modified }
    let abandoned: bool = $last != null and (date now) - $last > $idle
    # ponytail: one `timew` call per command keeps Timewarrior the only state; cache if it drags
    time active
    | if $in != null and $abandoned and $in.start < $last { time stop --at=$last | ignore } else { }
    | if $in == null or ($in.tags | sort) != ($tags | sort) { time start ...$tags | ignore }
    $stamp | path dirname | mkdir $in
    touch $stamp
  } catch {||
    get $.msg?
  } | if ($in | describe) == string {
    print --stderr $"track: disabled until PWD changes \(reason: ($in))"
    set-track disabled true
  }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

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
