# Utilities for interacting with Nushell modules: list them, track `use`/`hide` in a session registry, and
# define new modules from closures.
#
# This module is abstract (pure Nushell). `mods/local` adds the commands that resolve files through the
# owner's machine configuration (`edit`).

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]

use docgen
use error

# ——— constants ————————————————————————————————————————————————————————————————

const SHORT: table = [
  [prefix segments replace];
  [null [$nu.home-dir] ~]
  [$.mods_home!? [] @]
  [$.nupm_home!? [modules] '$']
]
const RE: record = {
  omit: '^(prelude|[_]{1}\w+|\w+\s{1}extern)$'
  # Every `use`/`hide` statement of a line (statements separated by `;`); `name` is the module path as written.
  module_actions: '(?:^|;)\s*(?:overlay\s+)?(?<action>use|hide)\s+(?<name>[^\s;]+)'
}

# ——— utilities ————————————————————————————————————————————————————————————————

## used_modules
alias set-used = kv set --table=used_modules
alias get-used = kv get --table=used_modules
alias drop-used = kv drop --table=used_modules
alias list-used = kv list --table=used_modules

## hidden_modules
alias set-hidden = kv set --table=hidden_modules
alias get-hidden = kv get --table=hidden_modules
alias drop-hidden = kv drop --table=hidden_modules
alias list-hidden = kv list --table=hidden_modules

def default-include-modules [
  --include-overlays
]: nothing -> table<name: string, module_id: int, commands: list, file: string> {
  # Hoisted out of the row condition: evaluating `scope commands` per module cost ~120ms at login.
  let visible: list<int> = scope commands | get $.decl_id
  let overlays: list<string> = overlay list | get $.name
  # Bare column names inside the parenthesised legs would parse as commands (`file`, `commands.decl_id`);
  # only the first leg may omit `$it`.
  scope modules | (
    where name !~ $RE.omit
    and ($it.file | path exists)
    and ($include_overlays or $it.name not-in $overlays)
    and ($it.commands.decl_id | intersect $visible | is-not-empty)
  ) | uniq-by module_id
}

def preserve-serialized-closure []: closure -> list<string> {
  view source $in | str replace --all --regex '^\{\|*\s*|\s*\}$' '' | lines | str trim --left | append ['']
}

# The module name a `use`/`hide` target refers to: `std/log` -> `log`, `./x.nu` -> `x`, `dir/mod.nu` -> `dir`.
def module-name []: string -> string {
  let p: record = $in | str trim --char '/' | path parse
  if $p.stem == mod and $p.extension == nu { $p.parent | path basename } else { $p.stem }
}

# The shorthand rows for the prefixes that are set: a variable's row is skipped while it is unset.
def build-mods-refs []: table -> table<find: string, replace: string> {
  each {|row|
    let base: oneof<nothing, string> = match $row.prefix { null => '' $p => ($env | get $p | default null) }
    if $base == null { return }
    {find: ($base | path join ...$row.segments) replace: $row.replace}
  } | where $it.find != ''
}

# The prefix shorthand rows, or the row whose prefix starts the piped path (most specific prefix first).
def module-file-shorthand []: [
  nothing -> table<find: string, replace: string>
  path -> oneof<nothing, record<find: string, replace: string>>
] {
  let p: oneof<nothing, path>;
  $env.mods_refs?
  | default ($SHORT | reverse | build-mods-refs)
  | if $p == null { } else {
    where ($p == $it.find or $p starts-with ($it.find | path join '')) | first
  }
}

# Replace a path's prefix with its shorthand (`~`, `@` for mods_home, `$` for nupm modules).
def shorten []: path -> path {
  let p: path;
  match ($p | module-file-shorthand) {
    null => $p
    {find: $f replace: $r} => ($r + ($p | str substring ($f | str length)..))
  }
}

# ——— environment ——————————————————————————————————————————————————————————————

# Sets `mods_home` (first existing NU_LIB_DIRS entry) and then `mods_refs` unless they are already set, and
# registers the `use`/`hide` tracking hook once (re-`use` adds nothing).
export-env {
  if $env.mods_home!? == null {
    let home: oneof<nothing, path> = $env.NU_LIB_DIRS? | default [] | where ($it | path exists) | first
    if $home != null { $env.mods_home = $home }
  }
  if $env.mods_refs!? == null { $env.mods_refs = module-file-shorthand }

  const name: string = 'mods::use_or_hide::update-mods-used'

  let existing: list = $env.config.hooks.pre_execution?
    | default []
    | where ($it | describe) starts-with record and $it.name? != null
    | get $.name!

  # Guard also ensures an already registered hook does not pick up this `hook` import invocation.
  if $existing not-has $name {
    use hook [ add is-enabled ]
    [
      [name disabled condition code];
      [
        $name
        false
        {|| (is-enabled --name=$name) and (commandline) =~ $RE.module_actions }
        {|| job spawn --description=$name { refresh (commandline) } | ignore }
      ]
    ] | add pre_execution
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Define a module inline and save it to `<directory>/<name>/mod.nu`; returns the file's path.
#
# The closure's body (without its braces) becomes the module source. Without `--directory`, the module is saved
# under `$env.mods_home`.
@category core
export def --env define [
  name: string
  # The name of this module
  block: closure
  # The module definition, as a closure with no parameters
  --directory (-d): directory
  # Save the module as `($name)/mod.nu` under this directory (default: `$env.mods_home`)
  --overwrite (-o)
  # Do not throw an error when overwriting existing module definition files
]: nothing -> path {
  let base: path = $directory
    | default $env.mods_home!?
    | default {
      error raise 'no directory to save the module under' --with={
        kind: missing_dependency
        help: 'pass --directory or set $env.mods_home'
      }
    }
  let directory: directory = $base | path expand --no-symlink | append $name | path join
  if not ($directory | path exists) { mkdir $directory }
  let path: path = $directory | path join mod.nu
  if not $overwrite and ($path | path exists) {
    error raise $"module '($name)' is already defined at '($path)'" --with={
      kind: conflict
      help: 'pass --overwrite to replace it'
    }
  }
  let source: list<string> = $block | preserve-serialized-closure
  try { $source | save --force --progress $path } catch {|e|
    $e | error raise $"could not save the module definition to '($path)'" --kind io
  }
  return $path
}

# Update the registry tracking loaded modules for this session.
#
# Piped `scope modules` rows are registered as used; a buffer's `use`/`hide` statements (several per line,
# separated by `;`, also with `overlay`) register or unregister the module they name (`use std/log` -> `log`).
@category core
export def refresh [
  buffer?: string
  # Register or unregister modules by parsing this commandline buffer
  --return (-r): string@[names module_ids all]
  # What data to return; names -> loaded module names, module_ids -> loaded module identifiers, all -> table of the prior
]: oneof<nothing, table> -> oneof<nothing, list<string>, list<int>, table<name: string, module_id: int>> {
  let queue: oneof<nothing, table>;
  let tracked: list<int> = list-used | get $.value | compact
  if $queue != null {
    # Add any untracked modules to the kv store
    for mod in ($queue | where module_id not-in $tracked) { set-used $mod.name $mod.module_id }
    # Ensure we are working with post-refresh data
    let hidden: table = list-hidden
    # Drop any shared `$.module_id`s from the used table if they are hidden
    for key in (list-used | where value in $hidden.value).key { drop-used $key }
  }
  if $buffer != null {
    for parsed in ($buffer | parse --regex $RE.module_actions) {
      let name: string = $parsed.name | module-name
      let mod_id: oneof<nothing, int> = (scope modules | where name == $name).0?.module_id?
      match $parsed.action {
        use => {
          # Ensure removal from the hidden modules
          drop-hidden $name | ignore
          # Add to the used modules, if not already set
          if (get-used $name) != $mod_id { set-used $name $mod_id }
        }
        hide => {
          # Ensure removal from the used modules
          drop-used $name | ignore
          # Add to the hidden modules, if not already set
          if (get-hidden $name) != $mod_id { set-hidden $name $mod_id }
        }
      }
    }
  }
  if $return == null { return }
  list-used | match $return {
    names => { get $.key }
    module_ids => { get $.value }
    all => { rename --column={key: name value: module_id} }
  }
}

# List the modules loaded in the current session (a `name`/`description`/`location` table), or one module's row.
@category core
export def --env list [
  name?: string@_module-names
  # The name of a module to return information about
  --short (-s)
  # Only return a list of module names, instead of the information table
  --commands (-c)
  # Include each module's exported commands
  --absolute (-a)
  # Disable truncation of file paths with shorthand characters
  --overlays (-o)
  # Include overlays in the returned list or table
  --update (-u)
  # Update the environment variable tracking loaded modules
  --hidden (-h)
  # Return a table of hidden modules (only combines with `--short`)
]: nothing -> oneof<list<string>, string, table, record> {
  if $hidden {
    list-hidden | if $short { get $.key } else {
      let ids: list<int> = $in.value
      scope modules | where module_id in $ids
    } | return $in
  }
  let ls: table = match ($name | describe) {
    nothing => (default-include-modules --include-overlays=$overlays)
    string => (scope modules | where name == $name)
  }
  if $update { $ls | refresh }
  $ls | if $short { get $.name } else {
    docgen collect ...($in.file | where ($it | path exists))
    | update $.module.description {|row|
      $row.module | get $.description!? $.extra_description!? | compact | str join (char newline) | str trim
    }
    | update $.module.file {|row|
      if $in ends-with mod.nu { path dirname } else { }
      | if $absolute { } else { shorten }
    } | reject --optional $.module.extra_description
    | if $commands { flatten module } else { get $.module | rename --column={file: location} }
  } | if $name != null { first } else { sort }
}

# Show the modules loaded in the current session, or define new ones.
#
## Contract 1: `record -> list<path>`
# - Mapping of module names to their definitions (closures), saved under `$env.mods_home`.
#
## Contract 2: `oneof<closure, record<name: string, definition: closure>> -> path`
# - Single module definition, either as a details record (optionally with `directory` and `overwrite`) or as a
#   closure with `$name` passed inline.
#
## Contract 3: `nothing -> oneof<table, list<string>, string>`
# - With no name and no `--all`: the tracked modules as a `name`/`module_id` table. With a name or `--all`: the
#   loaded module names (`--all` includes overlays), or the name itself when it is loaded.
#
# Every call first registers the currently loaded modules (`list --update`).
@category core
export def --env main [
  # nu-lint-ignore: add_doc_comment_exported_fn
  name?: string@_module-names
  # Name of a module to define or show information about
  --all (-a)
  # Include overlays in the entries returned or searched
]: [
  nothing -> oneof<table<name: string, module_id: int>, list<string>, string>
  record -> oneof<path, list<path>>
  closure -> path
] {
  let input: any;
  list --update --short | ignore
  match ($input | describe | str replace --regex '<.*' '') {
    closure if $name == null => {
      error raise 'name is required when defining a new module' --kind invalid_argument
    }
    closure => (define $name $input)
    nothing if not $all and $name == null => (list-used | rename --column={key: name value: module_id})
    nothing => (list --short --overlays=$all $name)
    record if $input not-has definition and ($input | is-not-empty) => {
      $input
      | transpose name definition
      | where ($it.name | is-not-empty) and ($it.definition | describe) == closure
      | each {|m| define $m.name $m.definition }
    }
    record => {
      let m: record = $input
        | default $name $.name
        | default false $.overwrite
        | default { error raise 'module definition is required' --kind invalid_argument } $.definition
        | default {
          error raise 'name is required when defining a new module' --kind invalid_argument
        } $.name
      define $m.name $m.definition --directory=$m.directory? --overwrite=$m.overwrite
    }
    $t => {
      error raise $"unsupported input type '($t)'" --with={
        kind: invalid_argument
        help: 'pipe a closure, a details record or a record of name/closure pairs'
      }
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _module-names []: nothing -> list { 'use ' | commandline complete | where $it !~ '(.nu|/)$' }
