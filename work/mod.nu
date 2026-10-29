# Ticket files, the local surface of Todoist tickets: `<repo>/docs/tickets/<slug>.toml` (v4 `ticket` schema).

# Spec: `/work/dev/nu/work/docs/2026-09-18_work-core.spec.md`.
# Path: /work/nu/dec/work/mod.nu

# TODO:
# - complete extraction of `ticket`-scoped items to the `./ticket/mod.nu` submodule
# - remove all validation logic from this module and import the helpers from ticket submodule
# - remove `repo` based project logic in favor of the new `proj` module that replaces it

# ——— imports ——————————————————————————————————————————————————————————————————

use ticket *
use completion "into completions"
use validate
use proj

# ——— aliases ——————————————————————————————————————————————————————————————————

# ——— constants ——————————————————————————————————————————————————————————————

# ——— completions —————————————————————————————————————————————————————————————

def _slugs []: nothing -> record { files | select slug repo | rename value description | into completions }
def _repos []: nothing -> record {
  proj list --long
  | rename --column={name: value}
  | insert description {|row| $row | format pattern '[{kind}] {name}' }
  | into completions
}
def _statuses []: nothing -> record { $STATUSES | into completions }
def _properties [context: string]: nothing -> record {
  let slugs: list<string> = files | get slug
  let slug: oneof<string, nothing> = $context | split row ' ' | where $it in $slugs | get 0?
  # Bound with `let`: a `try` in tail position does not catch once the caller pipes the result onward.
  let paths: list<string> = if $slug == null { [] } else {
    try { main $slug | get ticket | columns | wrap key | format pattern 'ticket.{key}' | prepend [version ticket tasks] } catch { [] }
  }
  $paths | into completions
}

# ——— definitions —————————————————————————————————————————————————————————————

# Load and validate a ticket; `--md` renders the remote issue body instead.
@category workelopment
@example 'read one property of a ticket' { work hooks-placement | get ticket.status }
export def main [
  slug: string@_slugs
  --repo (-r): string@_repos # Repository to look in when the slug exists in more than one
  --md # Render the ticket as the remote issue body (Markdown) instead of returning the record
]: nothing -> oneof<record, string> {
  let file: record = try { locate $slug $repo } catch { error make 'unable to locate ticket' }
  let doc: record = open $file.path
  let bad: oneof<record, nothing> = $doc | check $file
  if $bad != null {
    error make --unspanned ($bad | format pattern $"'($file.path)' {reason}; {hint}")
  } else {
    $doc | normalise | if $md { render } else { }
  }
}

# Tickets across the registered repositories.
@category workelopment
@example 'open tickets, newest first' { work list --status open }
export def list [
  --status (-s): string@_statuses
  --repo (-r): string@_repos
]: nothing -> oneof<table<slug: string, error: any>, table<slug: string, name: string, status: string, date: datetime, repo: string>> {
  files $repo | par-each {|f|
    try {
      main $f.slug --repo=$f.repo
      | get $.ticket!?
      | default {}
      | select $.slug! $.name!? $.status!? $.date!?
      | insert $.repo $f.repo
    } catch {
      get $.details!?
      | default {msg: $"unable to parse ticket for file '($f.name)'"}
      | wrap error
      | insert $.slug $f.slug
    }
  } | if $status != null { where $it not-has status or status == $status } else { }
  | sort-by --custom {|a b|
    if ([$a $b] | any ($it not-has date)) { return ($a has date) }
    ($a.date == $b.date and $a.slug < $b.slug) or $a.date > $b.date
  }
}

# One property of a ticket.
@category workelopment
@example 'the outcome of a ticket' { work query hooks-placement ticket.outcome }
export def query [
  slug: string@_slugs
  property: cell-path@_properties
  --repo (-r): string@_repos
]: nothing -> oneof<string, int, bool, datetime, list<any>, record, table, nothing> {
  # Bound with `let`: a `try` in tail position does not catch once the caller pipes the result onward.
  let out = main $slug --repo=$repo
    | try { get $property } catch {
      error make --unspanned $"no property ($property | to text | str replace '$.' '') in '($slug)'; run `work ($slug)` to see the record"
    }
  return $out
}

# Change a ticket and rewrite its file canonically; returns the path.
@category workelopment
@example 'open a ticket' { work edit hooks-placement --set {status: open} }
export def edit [
  slug: string@_slugs
  --repo (-r): string@_repos
  --set: record # Merged into `ticket` (D14)
  --add-task: record # `{content, description?, labels?}`, created in Todoist first
  --complete: list<string> = [] # Task contents to complete, in Todoist first
]: nothing -> path {
  if $set == null and $add_task == null and ($complete | is-empty) {
    error make --unspanned 'nothing to edit: pass `--set`, `--add-task` or `--complete`'
  }
  let file: record = locate $slug $repo
  let doc: record = main $slug --repo=$file.repo
  # ponytail: the Todoist write-through ships with `work sync` (plan Phase 5a); until then no ticket is linked for it
  if $add_task != null or ($complete | is-not-empty) {
    error make --unspanned $"'($slug)' has no Todoist task yet; run `work sync ($slug)` first"
  }
  $set | verify-settable
  let merged: record = $doc | update ticket { merge deep --strategy=overwrite $set }
  let bad: oneof<record, nothing> = $merged | check $file
  if $bad != null {
    error make --unspanned $'`--set` rejected: ($bad.reason?); nothing written'
  }
  $merged | normalise | write $file.path
}

# ——— internals ———————————————————————————————————————————————————————————————

# Ticket files of the registered repositories, or of `repo` alone.
def files [repo?: string]: nothing -> table<slug: string, repo: string, path: path> {
  let registry: table<name: string, path: path> = proj list | default []
  if $repo != null and $repo not-in ($registry | get $.name?) {
    error make --unspanned $"no registered repository named '($repo)'; run repo list to see them"
  }
  $registry | where $repo == null or name == $repo | par-each {|r|
    let d: path = $r.path | path join docs tickets
    mkdir $d; glob $"($d)/*.toml"
    | par-each {|p| path parse | {slug: $in.stem repo: $r.name path: $p} }
  } | flatten --all
}

# The one file a slug names (D3).
def locate [slug: string repo?: string]: nothing -> record<slug: string, repo: string, path: path> {
  files $repo | where slug == $slug | match ($in | length) {
    1 => (first)
    0 => {
      error make --unspanned $"no ticket named '($slug)' in the registered repositories; run work list to see them"
    }
    _ => {
      error make --unspanned $"slug '($slug)' found in repos ($in.repo | str join ', '); pass `--repo`"
    }
  }
}
