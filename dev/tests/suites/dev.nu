# `dev` against a scratch repository of ticket files: `test dev/tests/suites`.
use ../mod.nu *

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

def "before each" []: nothing -> record<root: path> {
  let root: path = mktemp --directory --suffix=-dev
  mkdir ($root | path join docs tickets)
  {root: $root}
}
def "after each" []: record -> nothing { rm --recursive --force $in.root }

def registry [...roots: path]: nothing -> record {
  {discovery: false path: ($roots | enumerate | each {|r| {name: $"scratch($r.index)" owner: me directory: $r.item} })}
}

# Write `alpha` with `edits` applied as literal replacements; returns the file's path.
def seed [root: path, --slug: string = alpha, --edits: record = {}]: nothing -> path {
  let path: path = $root | path join docs tickets $"($slug).toml"
  mkdir ($path | path dirname)
  $edits | items {|from to| {from: $from to: $to} }
  | reduce --fold=($ALPHA | str trim --left) {|e acc| $acc | str replace $e.from $e.to }
  | save --force $path
  $path
}

def fails [needle: string, code: closure]: nothing -> nothing {
  let msg = try { do $code | ignore; null } catch {|e| $e.msg }
  assert ($msg != null and $needle in $msg) $"expected an error containing '($needle)', got: ($msg)"
}

def "test list empty" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  assert equal (dev list) [] 'no ticket files'
  hide-env repo
  assert equal (dev list) [] 'no registry'
  fails 'no ticket named' { dev alpha }
}

def "test load" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  seed $t.root | ignore
  let doc = dev alpha
  assert equal $doc.ticket.slug alpha 'slug'
  assert equal ($doc.ticket.date | describe) datetime 'date is a datetime'
  assert equal $doc.ticket.status aborted 'status'
  assert equal [$doc.ticket.target $doc.ticket.extends ($doc.ticket.output | first).alias] [null null null] 'absent optionals read as null'
  assert equal $doc.tasks [] 'absent rows read as an empty list'
  assert equal $doc.ticket.reference.remote.index 5 'reference'
}

def "test list" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  seed $t.root | ignore
  assert equal (dev list | select slug name status repo) [{slug: alpha name: Alpha status: aborted repo: scratch0}] 'one row per file'
  assert equal (dev list --status open) [] 'status filter'
  assert equal (dev list --repo scratch0 | get slug) [alpha] 'repo filter'
  fails 'no registered repository' { dev list --repo nowhere }
  let broken = seed $t.root --slug broken --edits {'slug = "alpha"': 'slug = "broken"' 'status = "aborted"': 'status = "stalled"'}
  fails $broken { dev list }
}

def "test query" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  seed $t.root | ignore
  assert equal (dev query alpha ticket.outcome) singular 'a property'
  assert equal (dev query alpha ticket.target) null 'an absent optional'
  fails 'run dev alpha' { dev query alpha ticket.nope }
}

def "test edit" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  let path = seed $t.root
  assert equal (dev edit alpha --set {status: open}) $path 'returns the path'
  assert equal (open $path | get ticket.status) open 'status written'
  dev edit alpha --set {target: 'v0.4.0'} | ignore
  assert equal (dev alpha | get ticket.target) 'v0.4.0' 'target round-trips'
  assert ('"<Nothing>"' not-in (open --raw $path)) 'no null reaches the file'
  fails 'nothing to edit' { dev edit alpha }
  fails 'dev sync alpha' { dev edit alpha --add-task {content: x} }
  fails 'dev sync alpha' { dev edit alpha --complete [x] }
  let before = open --raw $path
  fails "'slug' is not one of them" { dev edit alpha --set {slug: beta} }
  fails "'reference' is not one of them" { dev edit alpha --set {reference: {}} }
  fails '--set rejected: status must be one of' { dev edit alpha --set {status: bogus} }
  assert equal (open --raw $path) $before 'a refused edit writes nothing'
}

def "test edit is canonical" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  let path = seed $t.root
  dev edit alpha --set {status: open} | ignore
  let once = open --raw $path
  dev edit alpha --set {status: open} | ignore
  assert equal (open --raw $path) $once 'editing twice yields identical bytes'
  assert equal (ls ($path | path dirname) | length) 1 'no temp file is left behind'
  let strict = python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' $path | complete
  assert equal $strict.exit_code 0 'tomllib parses the file'
  dev edit alpha --set {constraints: [] bindings: []} | ignore
  let doc = open $path
  assert equal $doc.ticket.constraints [] 'a required list is written when empty'
  assert ($doc.ticket not-has bindings) 'an empty optional list is compacted'
}

def "test validation" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  seed $t.root --edits {'version = "4.0.0"': 'version = "3.0.0"'} | ignore
  fails 'dev migrate alpha' { dev alpha }
  seed $t.root --edits {'status = "aborted"': 'status = "stalled"'} | ignore
  fails 'status must be one of draft, open, done, aborted' { dev alpha }
  seed $t.root --edits {'slug = "alpha"': 'slug = "beta"'} | ignore
  fails "but the file is named 'alpha'" { dev alpha }
  seed $t.root --edits {'outcome = "singular"': ''} | ignore
  fails 'is missing ticket.outcome' { dev alpha }
  seed $t.root --edits {'outcome = "singular"': 'outcome = 1'} | ignore
  fails 'ticket.outcome must be string, got int' { dev alpha }
  seed $t.root --edits {'date = "2026-08-21"': 'date = "someday"'} | ignore
  fails 'is not a date' { dev alpha }
  seed $t.root --slug 'v0.4.0' --edits {'slug = "alpha"': 'slug = "v0.4.0"'} | ignore
  fails 'no dots' { dev 'v0.4.0' }
  rm ($t.root | path join docs tickets 'v0.4.0.toml')
  seed $t.root | ignore
  "\n[[tasks]]\ncontent = \"write\"\nlabels = [\"-robot\"]\ncompleted = false\n"
  | save --append ($t.root | path join docs tickets alpha.toml)
  fails 'must be one of -human, -agent, -mixed' { dev alpha }
}

def "test duplicate slug" []: record -> nothing {
  let t: record = $in
  let other: path = mktemp --directory --suffix=-dev
  $env.repo = registry $t.root $other
  seed $t.root | ignore
  seed $other --edits {'status = "aborted"': 'status = "open"'} | ignore
  fails 'found in repos scratch0, scratch1; pass --repo' { dev alpha }
  assert equal (dev alpha --repo scratch1 | get ticket.status) open '--repo resolves it'
  assert equal (dev edit alpha --repo scratch1 --set {status: done}) ($other | path join docs tickets alpha.toml) 'edit honours --repo'
  rm --recursive --force $other
}

def "test md" []: record -> nothing {
  let t: record = $in
  $env.repo = registry $t.root
  let path = seed $t.root
  assert equal (dev alpha --md) $ALPHA_MD 'the fixture body'
  "\n[[tasks]]\ncontent = \"write the ADR\"\nlabels = [\"-human\"]\ncompleted = true\n\n[[tasks]]\ncontent = \"review\"\nlabels = []\ncompleted = false\n"
  | save --append $path
  dev edit alpha --set {name: null extends: [beta] outcome: ''} | ignore
  let md = dev alpha --md
  assert ($md | str starts-with "# alpha\n\n## Requirements") 'slug heading, empty outcome omitted'
  assert ($md | str contains "## Constraints\n\n- Gates nu-over-bash-hooks; no hook implementation before this freezes.\n- Decision class is author-owned (manual).\n\n## Extends\n\n- beta\n\n## Output") 'extends in Schema order'
  assert ($md | str ends-with "## Tasks\n\n- [x] write the ADR\n- [ ] review") 'task boxes, no trailing newline'
}
