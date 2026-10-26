# `work` against a scratch repository of ticket files: `test work/tests/suites`.

use /work/dev/nu/proj
use ../mod.nu *

const work: path = path self ../..

# The core spec's example document as `alpha`, plus an xabort row so nested condition bullets render.
const ALPHA: string = '
version = "4.0.0"

[ticket]
name = "Alpha"
slug = "alpha"
date = "2026-08-21"
status = "aborted"
outcome = "singular"
requirements = ["A definite stance with rationale, recorded where future contributors will find it."]
constraints = [
    "Gates nu-over-bash-hooks; no hook implementation before this freezes.",
    "Decision class is author-owned (manual).",
]

[[ticket.output]]
path = "docs/decisions/"
purpose = "Recorded decision: plugin-level hooks.json versus skill-scoped frontmatter."

[[ticket.scope.excluded]]
item = "Hook implementation"
deferred = "nu-over-bash-hooks"

[[ticket.landscape]]
scope = "internal"
synopsis = "No hooks shipped yet; placement undecided."
type = "greenfield"

[[ticket.bindings]]
kind = "xvalue"
item = "Freezing placement before implementation prevents rework across every future hook the plugin ships."
type = "sequencing-integrity"

[[ticket.bindings]]
kind = "xabort"
item = "Abort when upstream ships hooks"
type = "OR"
conditions = ["upstream ships", "the deadline passes"]

[ticket.reference.remote]
index = 5
url = "https://github.com/zaynram/nu-fluency/issues/5"
branch = "hooks-placement"
'

const ALPHA_MD: string = '# Alpha

singular

## Requirements

- A definite stance with rationale, recorded where future contributors will find it.

## Constraints

- Gates nu-over-bash-hooks; no hook implementation before this freezes.
- Decision class is author-owned (manual).

## Output

| path | purpose |
| --- | --- |
| docs/decisions/ | Recorded decision: plugin-level hooks.json versus skill-scoped frontmatter. |

## Out of scope

| item | deferred |
| --- | --- |
| Hook implementation | nu-over-bash-hooks |

## Landscape

| scope | synopsis | type |
| --- | --- | --- |
| internal | No hooks shipped yet; placement undecided. | greenfield |

## Bindings

- xvalue/sequencing-integrity: Freezing placement before implementation prevents rework across every future hook the plugin ships.
- xabort/OR: Abort when upstream ships hooks
  - upstream ships
  - the deadline passes'

@category before-each
def --env "before each" []: nothing -> record {
  use proj test
  let root: path = mktemp --directory --suffix .work
  mkdir ($root | path join docs tickets)
  let proj: record = {name: 'scratch' path: $root repo: 'me/scratch' vcs: null host: null}
  [$proj] | test before
  return $proj
}

@category after-each
def --env "after each" []: record -> nothing {
  rm --recursive --force $in.path
}

@category after-all
def --env "after all" []: record -> nothing {
  ignore
  use proj test
  test after
}

def registry [...roots: path]: nothing -> table { list --kind=test }

# Write `alpha` with `edits` applied as literal replacements; returns the file's path.
def seed [
  root: path
  --slug: string = alpha
  --edits: record = {}
]: nothing -> path {
  let path: path = $root | path join docs tickets $"($slug).toml"
  mkdir ($path | path dirname)
  $edits | items {|from to| {from: $from to: $to} }
  | reduce --fold=($ALPHA | str trim --left) {|e acc| $acc | str replace $e.from $e.to }
  | save --force $path
  return $path
}

def fails [needle: string code: closure]: nothing -> nothing {
  let output = try {
    let x = do --capture-errors $code
    {raised: false}
  } catch {||
    get $.details.msg $.details.help
    | compact --empty
    | ansi strip
    | str join (char nl)
    | {raised: true text: $in}
  }
  assert $output.raised 'the closure did not generate an error'
  assert ($output.text != null and $needle in $output.text) $"expected an error containing '($needle)', got: ($output.text)"
}

def "test list_empty" []: record -> nothing {
  let t: record = $in
  assert equal (work list) [] 'no ticket files'
  use proj test
  test after
  assert equal (work list) [] 'no registry'
  fails 'no ticket named' { work alpha }
}

def "test load" []: record -> nothing {
  let t: record = $in
  seed $t.path | ignore
  let doc = work alpha --repo=scratch
  assert equal $doc.ticket.slug alpha 'slug'
  assert equal ($doc.ticket.date | describe) datetime 'date is a datetime'
  assert equal $doc.ticket.status aborted 'status'
  assert equal [$doc.ticket.target $doc.ticket.extends ($doc.ticket.output | first).alias] [null null null] 'absent optionals read as null'
  assert equal $doc.tasks [] 'absent rows read as an empty list'
  assert equal $doc.ticket.reference.remote.index 5 'reference'
}

def "test list" []: record -> nothing {
  let t: record = $in
  seed $t.path | ignore
  assert equal (work list | select slug name status repo) [{slug: alpha name: Alpha status: aborted repo: scratch}] 'one row per file'
  assert equal (work list --status open) [] 'status filter'
  assert equal (work list --repo scratch | get slug) [alpha] 'repo filter'
  fails 'no registered repository' { work list --repo nowhere }
  let broken = seed $t.path --slug broken --edits {'slug = "alpha"': 'slug = "broken"' 'status = "aborted"': 'status = "stalled"'}
  fails $broken { work list }
}

def "test query" []: record -> nothing {
  let t: record = $in
  seed $t.path | ignore
  assert equal (work query alpha ticket.outcome) singular 'a property'
  assert equal (work query alpha ticket.target) null 'an absent optional'
  fails 'run work alpha' { work query alpha ticket.nope }
}

def "test edit" []: record -> nothing {
  let t: record = $in
  let path = seed $t.path
  assert equal (work edit alpha --set {status: open}) $path 'returns the path'
  assert equal (open $path | get ticket.status) open 'status written'
  work edit alpha --set {target: 'v0.4.0'} | ignore
  assert equal (work alpha | get ticket.target) 'v0.4.0' 'target round-trips'
  assert ('"<Nothing>"' not-in (open --raw $path)) 'no null reaches the file'
  fails 'nothing to edit' { work edit alpha }
  fails 'work sync alpha' { work edit alpha --add-task {content: x} }
  fails 'work sync alpha' { work edit alpha --complete [x] }
  let before = open --raw $path
  fails "'slug' is not one of them" { work edit alpha --set {slug: beta} }
  fails "'reference' is not one of them" { work edit alpha --set {reference: {}} }
  fails '--set rejected: ticket.status must be one of' { work edit alpha --set {status: bogus} }
  assert equal (open --raw $path) $before 'a refused edit writes nothing'
}

def "test edit_is_canonical" []: record -> nothing {
  let t: record = $in
  let path = seed $t.path
  work edit alpha --set {status: open} | ignore
  let once = open --raw $path
  work edit alpha --set {status: open} | ignore
  assert equal (open --raw $path) $once 'editing twice yields identical bytes'
  assert equal (ls ($path | path dirname) | length) 1 'no temp file is left behind'
  let strict = python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' $path | complete
  assert equal $strict.exit_code 0 'tomllib parses the file'
  work edit alpha --set {constraints: [] bindings: []} | ignore
  let doc = open $path
  assert equal $doc.ticket.constraints [] 'a required list is written when empty'
  assert ($doc.ticket not-has bindings) 'an empty optional list is compacted'
}

def "test validation" []: record -> nothing {
  let t: record = $in
  seed $t.path --edits {'version = "4.0.0"': 'version = "3.0.0"'} | ignore
  fails "run `migrate 'alpha'`" { work alpha }
  seed $t.path --edits {'status = "aborted"': 'status = "stalled"'} | ignore
  fails 'status must be one of [draft, open, done, aborted]' { work alpha }
  seed $t.path --edits {'slug = "alpha"': 'slug = "beta"'} | ignore
  fails "but the file is named 'alpha'" { work alpha }
  seed $t.path --edits {'outcome = "singular"': ''} | ignore
  fails 'ticket.outcome is missing' { work alpha }
  seed $t.path --edits {'outcome = "singular"': 'outcome = 1'} | ignore
  fails 'ticket.outcome must be string, got int' { work alpha }
  seed $t.path --edits {'date = "2026-08-21"': 'date = "someday"'} | ignore
  fails 'is not a date' { work alpha }
  seed $t.path --slug 'v0.4.0' --edits {'slug = "alpha"': 'slug = "v0.4.0"'} | ignore
  fails 'no dots' { work 'v0.4.0' }
  rm ($t.path | path join docs tickets 'v0.4.0.toml')
  seed $t.path | ignore
  "\n[[tasks]]\ncontent = \"write\"\nlabels = [\"-robot\"]\ncompleted = false\n"
  | save --append ($t.path | path join docs tickets alpha.toml)
  fails 'must be one of -human, -agent, -mixed' { work alpha }
}

# A key the schema does not name fails the load instead of being ignored and written back.
def "test unknown_key" []: record -> nothing {
  let t: record = $in
  seed $t.path --edits {'outcome = "singular"': "outcome = \"singular\"\nextnds = [\"beta\"]"} | ignore
  fails 'ticket.extnds is not a known key' { work alpha }
  seed $t.path --edits {'purpose = "Recorded': "colour = \"red\"\npurpose = \"Recorded"} | ignore
  fails 'ticket.output.colour is not a known key' { work alpha }
  seed $t.path | ignore
  "\n[[tasks]]\ncontent = \"write\"\npriority = 1\n" | save --append ($t.path | path join docs tickets alpha.toml)
  fails 'tasks.priority is not a known key' { work alpha }
}

def "test limits" []: record -> nothing {
  let t: record = $in
  let path = seed $t.path
  let before = open --raw $path
  fails '--set rejected: ticket.name is 81 characters, max 80' { work edit alpha --set {name: ('' | fill --width 81 --character x)} }
  fails '--set rejected: ticket.requirements has 13 items, max 12' { work edit alpha --set {requirements: (1..13 | each { $"r($in)" })} }
  fails '--set rejected: ticket.extends.0' { work edit alpha --set {extends: ['Bad.Slug']} }
  fails '--set rejected: ticket.landscape.0.scope must be one of internal, external' { work edit alpha --set {landscape: [{scope: sideways synopsis: s}]} }
  fails '--set rejected: ticket.scope must be record, got int' { work edit alpha --set {scope: 7} }
  assert equal (open --raw $path) $before 'a refused edit writes nothing'
}

def "test duplicate_slug" []: record -> nothing {
  let t: record = $in
  let other: path = mktemp --directory --suffix .work
  seed $t.path | ignore
  seed $other --edits {'status = "aborted"': 'status = "open"'} | ignore
  fails 'found in repos scratch0, scratch1; pass --repo' { work alpha }
  assert equal (work alpha --repo scratch1 | get ticket.status) open '--repo resolves it'
  assert equal (work edit alpha --repo scratch1 --set {status: done}) ($other | path join docs tickets alpha.toml) 'edit honours --repo'
  rm --recursive --force $other
}

def "test md" []: record -> nothing {
  let t: record = $in
  let path = seed $t.path
  assert equal (work alpha --md) $ALPHA_MD 'the fixture body'
  "\n[[tasks]]\ncontent = \"write the ADR\"\nlabels = [\"-human\"]\ncompleted = true\n\n[[tasks]]\ncontent = \"review\"\nlabels = []\ncompleted = false\n"
  | save --append $path
  work edit alpha --set {name: null extends: [beta] outcome: ''} | ignore
  let md = work alpha --md
  assert ($md | str starts-with "# alpha\n\n## Requirements") 'slug heading, empty outcome omitted'
  assert ($md | str contains "## Constraints\n\n- Gates nu-over-bash-hooks; no hook implementation before this freezes.\n- Decision class is author-owned (manual).\n\n## Extends\n\n- beta\n\n## Output") 'extends in Schema order'
  assert ($md | str ends-with "## Tasks\n\n- [x] write the ADR\n- [ ] review") 'task boxes, no trailing newline'
}
