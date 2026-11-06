# Extract structured documentation models from Nushell source.
#
# This module is the extraction layer of the docgen pipeline — and, until
# ADR-0002 freezes the integration question, deliberately the whole module.
# Each target is imported by a clean child interpreter and introspected
# through `scope modules` / `scope commands`, so the model is semantic by
# construction: what `help` shows and what the model records are the same
# data. Rendering and example execution are decision-dependent layers and
# do not live here.
#
# Boundaries, by design: a module that fails to import raises (a parse-broken
# module is a CI signal, not a gap to skip over); private helpers are
# invisible; constants are recorded by name and type only, since Nushell
# exposes their values solely for the module imported directly. Nested
# `export module` blocks are traversed, one child import per submodule, and
# emitted as rows of their own.

# nu-lint-ignore-file: add_doc_comment_exported_fn

use error

# The introspection program run inside the child interpreter. %USE% (one or
# more import statements), %WHERE% (the root module predicate) and %PATH%
# (the submodule chain to descend) are substituted by `introspect`; nuon on
# stdout is the only output. Exports are joined by declaration id, which
# is why each submodule needs a child of its own: a submodule's declarations
# are visible to `scope` only once it is imported itself. The child imports
# this library's `error` module (its root heads the include path) to raise
# its own failures, which reach the caller as the text of its stderr.

const ROOT: path = path self .. | path expand --strict
const CHILD_SCRIPT = r#'
use error
%USE%
let found = scope modules | where %WHERE%
if ($found | is-empty) {
  error raise 'the module was imported but is not in scope' --kind not_found
}
# descend by name: a re-exported module (`export use`) never appears in
# `scope modules` on its own, only under its parent
let module = %PATH% | reduce --fold ($found | first) {|name, parent|
  let sub = $parent.submodules | where name == $name
  if ($sub | is-empty) {
    error raise $"no submodule named '($name)' under '($parent.name)'" --kind not_found
  }
  $sub | first
}
let carried = $module.commands.decl_id | append $module.aliases.decl_id
{
  module: ($module | select name description extra_description file)
  commands: (
    scope commands
    | where decl_id in $module.commands.decl_id
    | select name category description extra_description search_terms signatures examples is_const
    | sort-by name
  )
  aliases: (
    scope aliases
    | where decl_id in $module.aliases.decl_id
    | select name expansion description
    | sort-by name
  )
  constants: ($module.constants | select name type | sort-by name)
  # a re-exported module (`export use`) already surfaces on its parent as
  # prefixed commands, so only submodules the parent does not carry get rows
  submodules: (
    $module.submodules | where {|sub|
      let own = $sub.commands.decl_id | append $sub.aliases.decl_id
      ($own | is-empty) or ($own | any $it not-in $carried)
    } | get name
  )
}
| to nuon
'#

# Resolve one collect target into the child's `use` argument and the
# `scope modules` predicate pinning down the imported module. A target is a
# path when it contains a path separator, ends in `.nu`, or exists on disk
# relative to the current directory (so `.` and `..` are paths); anything
# else is a module name resolved through the child's lib dirs. A path that
# does not exist is looked up in the lib dirs too (see `locate`). Paths are
# expanded here so the predicate can match on the module's file identity,
# with a bare `mod.nu` target resolved to its parent directory (importing
# the file directly would name the module `mod`).
def resolve [target: string]: nothing -> record<use: string, where: string> {
  let is_path: bool = $target =~ '[/\\]' or ($target ends-with .nu) or ($target | path exists)
  if not $is_path {
    return {use: $target, where: $"name == ($target | to nuon)"}
  }
  let full: path = try { locate $target | path expand --strict } catch {|e|
    $e | error raise $"target '($target)' does not exist" --kind not_found
  }
  let file: path = match ($full | path type) {
    dir => ($full | path join mod.nu)
    _ => $full
  }
  let entry: path = if ($file | path basename) == mod.nu {
    $file | path dirname
  } else {
    $file
  }
  {use: $entry, where: $"file == ($file | to nuon)"}
}

# A path target on disk: as given when it exists (relative to the current
# directory), else the first lib dir entry it names, as `use` resolves
# `completion/local`: a module file, or a directory with a `mod.nu`. A target
# found nowhere is returned unchanged.
def locate [target: path]: nothing -> path {
  if ($target | path exists) { return $target }
  include-dirs
  | each {|dir| $dir | path join $target }
  | where (($it | path type) == file or ($it | path join mod.nu | path exists))
  | get --optional 0
  | default $target
}

# Library directories the child resolves bare module names against, first
# match wins: this repository's root, the caller's `$env.NU_LIB_DIRS`, the
# parse-time `$NU_LIB_DIRS` constant, then the nupm modules directory
# (`$env.NUPM_HOME/modules`, default `<data-dir>/../nupm/modules`).
def include-dirs []: nothing -> list<string> {
  [
    $ROOT
    ...$env.NU_LIB_DIRS
    ...$NU_LIB_DIRS
    ($env.NUPM_HOME? | default ($nu.data-dir | path basename --replace nupm) | path join modules)
  ] | uniq
}

# Run the introspection program in a clean child interpreter and return the
# raw scope metadata of one module: `ctx.uses` are the import statements,
# `ctx.where` pins the root module, `ctx.path` names the submodule chain to
# descend. The child seam keeps the caller's session state out of the model
# and turns an import failure into a loud, attributable error.
def introspect [ctx: record]: nothing -> record {
  let script = $CHILD_SCRIPT
    | str replace %USE% ($ctx.uses | str join (char newline))
    | str replace %WHERE% $ctx.where
    | str replace %PATH% ($ctx.path | to nuon)
  let out = ^$nu.current-exe --no-config-file --include-path=(include-dirs | str join (char esep)) --commands $script
    | complete
  if $out.exit_code != 0 {
    error raise $"the module could not be collected after `($ctx.uses | last)`" ...{
      kind: external_failure
      advice: ($out.stderr | str trim)
    }
  }
  $out.stdout | from nuon
}

# Collect a module and, recursively, its submodules: one row each, module
# names qualified by their parent chain. Submodules report no file of their
# own, so they inherit the nearest ancestor's.
def collect-tree [ctx: record]: nothing -> list<record> {
  let raw = introspect $ctx
  let root = $ctx.root | default $raw.module.name
  let name = [$root] | append $ctx.path | str join ' '
  let file = if ($raw.module.file | path exists) { $raw.module.file } else { $ctx.file }
  [($raw | reject submodules | update module { update name $name | update file $file })]
  | append (
    $raw.submodules | each {|sub|
      collect-tree {
        uses: ($ctx.uses | append $"use ($raw.module.name | to nuon) ($sub | to nuon)")
        where: $ctx.where
        path: ($ctx.path | append $sub)
        root: $root
        file: $file
      }
    } | flatten
  )
}

# Comment lines that are linter or formatter directives rather than prose.
const DIRECTIVE: string = '^\s*(nu-lint-ignore(-file)?|topiary)\s*:'

# Drop directive lines (`# nu-lint-ignore: …`, `# topiary: …`) that Nushell
# folds into a doc comment alongside its prose.
def strip-directives []: string -> string {
  lines | where $it !~ $DIRECTIVE | str join (char newline)
}

# Reshape one signature overload's rows into the model's parameter table,
# keeping only rows a caller can actually pass (input/output rows are
# surfaced separately as `io`).
def params-of []: any -> table {
  where parameter_type in [positional rest named switch]
  | each {|p|
    {
      name: $p.parameter_name
      kind: $p.parameter_type
      type: (if $p.parameter_type == switch { 'bool' } else { $p.syntax_shape | default any })
      required: (match $p.parameter_type {
        positional => (not ($p.is_optional | default false))
        _ => false
      })
      short: $p.short_flag
      default: $p.parameter_default
      description: $p.description
      completion: $p.completion
    }
  }
}

# One input/output type pair per signature overload.
def io-of []: record -> table {
  values
  | each {|rows|
    {
      input: ($rows | where parameter_type == input | get --optional 0.syntax_shape | default any)
      output: ($rows | where parameter_type == output | get --optional 0.syntax_shape | default any)
    }
  }
}

# Reshape one raw `scope commands` row into the documentation model. The
# parameter list is identical across overloads, so it comes from the first;
# io keeps every overload's pair.
def normalize []: record -> record {
  let raw = $in
  {
    name: $raw.name
    description: ($raw.description | strip-directives)
    extra_description: ($raw.extra_description | strip-directives)
    search_terms: $raw.search_terms
    category: $raw.category
    params: ($raw.signatures | values | get --optional 0 | default [] | params-of)
    io: ($raw.signatures | io-of)
    examples: $raw.examples
    is_const: $raw.is_const
  }
}

# Extract the documentation model for one or more Nushell modules.
#
# Each target is either a module name (resolved against this repository's
# root, the caller's NU_LIB_DIRS and the nupm modules directory) or a
# filesystem path to a module directory, its mod.nu, or a single-file
# module; a target containing a path separator, ending in `.nu`, or existing
# on disk (including `.` and `..`) is a path. A path that does not exist from
# the current directory is looked up under the same lib dirs, so
# `collect completion/local` works anywhere. The result is one row per
# target plus one per nested submodule (named by its parent chain, e.g.
# `nested sub`): the module's own metadata plus normalized tables of
# its exported commands, aliases, and constants, each sorted for diff-stable
# output. Command names are the ones in scope after importing that row's
# module (`main` shown as the module name). Persist the diffable IR snapshot
# by piping through `to nuon`.
@example "collect a library module and list its command names" {
  collect completion | first | get commands.name
}
@example "persist a module directory's model as a nuon snapshot" {
  collect ./docgen | to nuon --indent 2 | save docs/api.nuon
}
export def collect [
  ...targets: string # module names or paths (directory, mod.nu, or file.nu)
]: nothing -> table {
  if ($targets | is-empty) {
    error raise 'at least one module target is required' ...{
      kind: invalid_argument
      advice: 'give a module name, or the path of a module directory, its mod.nu, or a single-file module'
    }
  }
  $targets | each {|target|
    let t = resolve $target
    collect-tree {uses: [$"use ($t.use | to nuon)"], where: $t.where, path: [], root: null, file: ''}
  } | flatten | each {|raw|
    {
      module: (
        $raw.module
        | update description { strip-directives }
        | update extra_description { strip-directives }
      )
      commands: ($raw.commands | each { normalize })
      aliases: ($raw.aliases | update description { strip-directives })
      constants: $raw.constants
    }
  }
}

# Entry point: `docgen <targets...>` delegates to `docgen collect`.
export def main [
  ...targets: string # module names or paths (directory, mod.nu, or file.nu)
]: nothing -> table {
  collect ...$targets
}
