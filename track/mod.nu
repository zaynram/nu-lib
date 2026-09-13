# Automatic Timewarrior tracking of the repository and branch in focus, tagged with the matched Todoist task.

use ../time
use ../todo

# ——— constants ————————————————————————————————————————————————————————————————

# Matches are cached per shell for this long before `todo find` runs again for the same branch.
const MATCH_TTL: duration = 1hr

# ——— definitions ——————————————————————————————————————————————————————————————

# This shell's focus, cached in `$env.TRACK`.
#
# `root` is null outside a repository. `head` is the repository's HEAD file, which `sync` reads to
# notice checkouts without a subprocess. `task` is the matched Todoist task content, or null.
@category productivity
export def --env focus [
  --refresh (-r) # Recompute from the current directory instead of returning the cache
]: nothing -> oneof<nothing, record> {
  if not $refresh { return $env.TRACK? }
  let git: record = ^git rev-parse --show-toplevel --absolute-git-dir | complete
  if $git.exit_code != 0 {
    $env.TRACK = {root: null}
    return $env.TRACK
  }
  let paths: list<string> = $git.stdout | lines
  let root: path = $paths | first
  let repo: string = $root | path basename
  let head: path = $paths | last | path join HEAD
  let branch: string = read-branch $head
  let key: string = $'($repo)@($branch)'
  let matches: record = $env.TRACK?.matches? | default {}
  let hit: oneof<nothing, record> = $matches | get --optional $key
  let task: oneof<nothing, string> = if $hit != null and (date now) - $hit.at < $MATCH_TTL { $hit.task } else {
    # ponytail: one `td` call (~0.8s) per new repo@branch per shell; a shared file cache if that drags
    try { todo find $branch --project $repo | get --optional content }
  }
  $env.TRACK = {
    root: $root
    repo: $repo
    head: $head
    branch: $branch
    task: $task
    tags: [$'#($repo)' ($task | default $branch)]
    matches: ($matches | upsert $key {task: $task at: (date now)})
  }
  $env.TRACK
}

# Align the open Timewarrior interval with this shell's focus; the pre_execution hook body.
#
# 1. If the activity stamp is older than `--idle`, the open interval ends at the stamp.
# 2. If the open interval's tags differ from the focus tags, a new interval starts.
# 3. The stamp is touched. Outside a repository nothing happens; after an error the shell's
#    tracking stays off until the next `focus --refresh`.
@category productivity
export def --env sync [
  --idle: duration = 30min # Gap after which the open interval counts as abandoned
]: nothing -> nothing {
  let cached: oneof<nothing, record> = $env.TRACK?
  if $cached == null or ($cached.root != null and (read-branch $cached.head) != $cached.branch) {
    focus --refresh | ignore
  }
  if $env.TRACK.root == null or ($env.TRACK.disabled? | default false) { return }
  let failure: oneof<nothing, string> = try {
    let stamp: path = time db | path join track.stamp
    let last: oneof<nothing, datetime> = try { ls $stamp | get 0.modified }
    let abandoned: bool = $last != null and (date now) - $last > $idle
    # ponytail: one `timew` call per command keeps Timewarrior the only state; cache if it drags
    time active
    | if $in != null and $abandoned and $in.start < $last { time stop --at=$last | ignore } else { }
    | if $in == null or ($in.tags | sort) != ($env.TRACK.tags | sort) { time start ...$env.TRACK.tags | ignore }
    mkdir ($stamp | path dirname)
    touch $stamp
    null
  } catch {|err| $err.msg }
  if $failure != null {
    $env.TRACK.disabled = true
    print --stderr $"track: off in this shell until the next directory change: ($failure)"
  }
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# Branch name from a HEAD file, or the short commit hash when detached.
def read-branch [head: path]: nothing -> string {
  open --raw $head | str trim
  | if ($in | str starts-with 'ref: refs/heads/') { str replace 'ref: refs/heads/' '' } else { str substring 0..<8 }
}
