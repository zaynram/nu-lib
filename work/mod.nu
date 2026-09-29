# Ticket files, the local surface of Todoist tickets: `<repo>/docs/tickets/<slug>.toml` (v4 `ticket` schema).
# Spec: `work/docs/2026-09-18_dev-core.spec.md`.

# TODO:
# - complete extraction of `ticket`-scoped items to the `./ticket/mod.nu` submodule
# - remove all validation logic from this module and import the helpers from ticket submodule
# - remove `repo` based project logic in favor of the new `proj` module that replaces it

# ——— imports ——————————————————————————————————————————————————————————————————

use ticket *
use ../completion "into completions"
use ../validate
use ../repo

# ——— aliases ——————————————————————————————————————————————————————————————————

# ——— constants ——————————————————————————————————————————————————————————————

# ——— completions —————————————————————————————————————————————————————————————

def _slugs []: nothing -> record { files | select slug repo | rename value description | into completions }
def _repos []: nothing -> record { repo list | rename --column={name: value} | insert description {|row| $row | format pattern '[{owner}] {directory}' } | into completions }
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
@category development
@example 'read one property of a ticket' { dev hooks-placement | get ticket.status }
export def main [
  slug: string@_slugs
  --repo (-r): string@_repos # Repository to look in when the slug exists in more than one
  --md # Render the ticket as the remote issue body (Markdown) instead of returning the record
]: nothing -> oneof<record, string> {
  let file: record = locate $slug $repo
  let doc: record = open $file.path
  let bad: oneof<record, nothing> = $doc | check $file
  if $bad != null { error make --unspanned ($bad | format pattern $"'($file.path)'{reason}; {next}") }
  $doc | normalise | if $md { render } else { }
}

# Tickets across the registered repositories.
@category development
@example 'open tickets, newest first' { dev list --status open }
export def list [
  --status (-s): string@_statuses
  --repo (-r): string@_repos
]: nothing -> table<slug: string, name: string, status: string, date: datetime, repo: string> {
  # A `for`, not `each`: a closure wraps the load error of a broken file, hiding the message that names it.
  mut rows: list<record> = []
  for f in (files $repo) {
    $rows ++= [(main $f.slug --repo=$f.repo | get ticket | select slug name status date | insert repo $f.repo)]
  }
  $rows
  | if $status != null { where status == $status } else { }
  | sort-by --custom {|a b| if $a.date == $b.date { $a.slug < $b.slug } else { $a.date > $b.date } }
}

# One property of a ticket.
@category development
@example 'the outcome of a ticket' { dev query hooks-placement ticket.outcome }
export def query [
  slug: string@_slugs
  property: cell-path@_properties
  --repo (-r): string@_repos
]: nothing -> oneof<string, int, bool, datetime, list<any>, record, table, nothing> {
  # Bound with `let`: a `try` in tail position does not catch once the caller pipes the result onward.
  let out = main $slug --repo=$repo
    | try { get $property } catch {
      error make --unspanned $"no property ($property | to text | str replace '$.' '') in '($slug)'; run `dev ($slug)` to see the record"
    }
  return $out
}

# Change a ticket and rewrite its file canonically; returns the path.
@category development
@example 'open a ticket' { dev edit hooks-placement --set {status: open} }
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
  # ponytail: the Todoist write-through ships with `dev sync` (plan Phase 5a); until then no ticket is linked for it
  if $add_task != null or ($complete | is-not-empty) {
    error make --unspanned $"'($slug)' has no Todoist task yet; run `dev sync ($slug)` first"
  }
  $set | verify-settable
  let merged: record = $doc | update ticket { merge deep --strategy=overwrite $set }
  let bad: oneof<record, nothing> = $merged | check $file
  if $bad != null {
    error make --unspanned $'`--set` rejected: ($bad.reason | str replace --regex '^:? ' ''); nothing written'
  }
  $merged | normalise | write $file.path
}

# ——— internals ———————————————————————————————————————————————————————————————

# Ticket files of the registered repositories, or of `repo` alone.
def files [repo?: string]: nothing -> table<slug: string, repo: string, path: path> {
  let registry: list<record> = repo list | default []
  if $repo != null and $repo not-in ($registry | get $.name?) { error make --unspanned $"no registered repository named '($repo)'; run repo list to see them" }
  $registry | where $repo == null or name == $repo | par-each {|r|
    let d: path = $r.directory | path join docs tickets
    mkdir $d; glob $"($d)/*.toml"
    | par-each {|p| path parse | {slug: $in.stem repo: $r.name path: $p} }
  } | flatten --all
}

# The one file a slug names (D3).
def locate [slug: string repo?: string]: nothing -> record<slug: string, repo: string, path: path> {
  files $repo | where slug == $slug | match ($in | length) {
    0 => (error make --unspanned $"no ticket named '($slug)' in the registered repositories; run dev list to see them")
    1 => { first }
    _ => { error make --unspanned $"slug '($slug)' found in repos ($in.repo | str join ', '); pass `--repo`" }
  }
}
