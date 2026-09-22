# Utilities for interacting with Nushell modules.

# ——— imports ——————————————————————————————————————————————————————————————————

use std-rfc/kv [ "kv set" "kv get" "kv drop" "kv list" ]
use ../config
use ../path
use ../util editor
use ../completion "into completions"
use ../prelude NU_LIB_DIRS
use docgen

# ——— constants ————————————————————————————————————————————————————————————————

const SHORT: table = [
  [prefix segments replace];
  [null [$nu.home-dir] ~]
  [$.mods_home!? [] @]
  [$.nupm_home!? [modules] '$']
]
const RE: record = {
  omit: '^(prelude|[_]{1}\w+|\w+\s{1}extern)$'
  module_actions: '^\s*(?:overlay\s+)?(?<action>use|hide)\s+(?<name>[\w\-]+)\b'
}
const EXCLUDE: list<string> = [**/nupm+/** **/tests/** **/tests.nu **/*.bak*/**]

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

# Glob the `.nu` definitions under the piped directories.
def nu-glob []: oneof<path, list<path>> -> list<path> {
  append [] | par-each {||
    path rejoin ** *.nu
    | into glob
    | glob $in --no-dir --depth=3 --exclude=$EXCLUDE
  } | flatten | uniq | sort
}

alias build-mods-refs = each {|row|
  select $.replace | insert find (match $row.prefix { null => '' $p => ($env | get $p | to text) } | path join ...$row.segments)
}

def module-file-shorthand []: [
  nothing -> table<find: string, replace: string>
  path -> oneof<nothing, record<find: string, replace: string>>
] {
  let p: oneof<nothing, path>;
  $env.mods_refs?
  | default ($SHORT | reverse | build-mods-refs)
  | if $p == null { } else { where $p has $it.find | first }
}

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  [
    [name value];
    [mods_refs ($env.mods_refs!? | default (module-file-shorthand))]
    [mods_home ($env.mods_home!? | default ($env.NU_LIB_DIRS? | where { path exists }).0?)]
  ] | difference ($env | select $.mods_home!? $.mods_refs!? | transpose name value)
  | if $in != [] { transpose --ignore-titles --header-row --as-record | load-env }

  const name: string = 'mods::use_or_hide::update-mods-used'
  # Guard also ensures an already registered hook does not pick up this `hook` import invocation.
  if ($env.config.hooks.pre_execution? | where $it has name).name not-has $name {
    use ../hook [ add is-enabled ]
    [
      [name disabled condition code];
      [
        $name
        false
        {|| (is-enabled --name=$name) and (commandline) =~ $RE.module_actions }
        {|| refresh (commandline) }
      ]
    ] | add pre_execution
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Define a module inline and save it to a file.
@category core
export def --env define [
  name: string
  # The name of this module
  block: closure
  # The module definition, as a closure with no parameters
  --directory (-d): directory
  # Save the module as `($name)/mod.nu` under this directory
  --overwrite (-o)
  # Do not throw an error when overwriting existing module definition files
]: nothing -> path {
  let directory: directory = $directory | default $env.mods_home | path expand --no-symlink | append $name | path join
  if not ($directory | path exists) { mkdir $directory }
  let path: path = $directory | path join mod.nu
  if not $overwrite and ($path | path exists) { error make --unspanned $"module '($name)' is already defined" }
  $block | preserve-serialized-closure | try {
    save --force --progress $path
  } catch { error make --unspanned 'unable to save module definition' }
  return $path
}

# Open a module or script definition file by name, or return its path.
@category core
export def edit [
  target: string@_definitions # Name of the module or script to target
  --get (-g) # Return the resolved path instead of opening it
]: nothing -> oneof<nothing, path> {
  [$config.USER.modules $config.USER.scripts]
  | nu-glob
  | where $it has $target
  | sort-by {|p| $target not-in ($p | path split) } # exact segment matches first
  | first
  | match ($in | describe) {
    nothing => (error make --unspanned $"no definition found for '($target)'")
    _ if $get => { path expand }
    _ => { editor }
  }
}

# Update the registry tracking loaded modules for this session.
@category core
export def refresh [
  buffer?: string
  # Register or unregister a module by parsing this commandline buffer
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
    let parsed: record = $buffer | parse --regex $RE.module_actions | into record
    let mod_id: oneof<nothing, int> = (scope modules | where name == $parsed.name?).0?.module_id?
    match $parsed.action? {
      use => {
        # Ensure removal from the hidden modules
        drop-hidden $parsed.name | ignore
        # Add to the used modules, if not already set
        if (get-used $parsed.name) != $mod_id { set-used $parsed.name $mod_id }
      }
      hide => {
        # Ensure removal from the used modules
        drop-used $parsed.name | ignore
        # Add to the hidden modules, if not already set
        if (get-hidden $parsed.name) != $mod_id { set-hidden $parsed.name $mod_id }
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

# List the modules loaded in the current session.
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
]: nothing -> oneof<list<string>, table<module: record, commands: table>, table<name: string, description: string, location: path>> {
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
    | update $.module.description {|row| $row.module | get $.description!? $.extra_description!? | compact | str join (char newline) }
    | update $.module.file {|row|
      if $in ends-with mod.nu { path dirname } else { }
      | if $absolute { } else { match ($in | module-file-shorthand) { null => ($in) {find: $f replace: $r} => ($in | str replace $f $r) } }
    } | reject --optional $.module.extra_description
    | if $commands { flatten module } else { get module | rename --column={file: location} }
  } | if $name != null { first } else { sort }
}

# Show the modules loaded in the current session and their exports, or define a new one.
#
## Contract 1: `record -> oneof<path, list<path>>`
# - Mapping of module names to their definitions. Options are not supported in this contract.
#
## Contract 2: `oneof<closure, record<name: string, definition: closure>> -> path`
# - Single module definition, either as a details record or as a closure with `$name` passed inline. Options are supported when defined in the input record.
#
## Contract 3: `nothing -> oneof<list<string>, table<...>, record<...>>`
# - Query module information, optionally for a single module (targeted by name).
#
### By default, when no arguments or input are provided, the names of the loaded modules will be returned as a list of strings.
@category core
export def --env main [
  # nu-lint-ignore: add_doc_comment_exported_fn
  name?: string@_module-names
  # Name of a module to define or show information about
  --all (-a)
  # Include overlays in the entries returned or searched
]: [
  nothing -> list<string>
  record -> oneof<path, list<path>>
  oneof<closure, record<name: string, definition: closure>, record<name: string, definition: closure, directory: path, overwrite: bool>> -> path
  nothing -> oneof<table<name: string, exports: table<name: string, type: string>, path: path>, record<name: string, exports: table<name: string, type: string>, path: path>>
] {
  list --update
  $in | match ($in | describe) {
    closure if $name == null => (error make --unspanned 'name is required when defining a new module')
    closure => (define $name $in)
    nothing if not $all and $name == null => (list-used | rename --column={key: name value: module_id})
    nothing => (list --short --overlays=$all $name)
    _ if $in not-has definition and ($in | is-not-empty) => {
      transpose name definition
      | where ($it.name | is-not-empty) and ($it.definition | describe) == closure
      | par-each {|| define $in.name $in.definition }
    }
    _ => {
      let m: record = default $name name | default $env.mods_home directory | default false overwrite
      if $m.definition == null { error make --unspanned 'module definition is required' }
      if $m.name == null { error make --unspanned 'name is required when defining a new module' }
      define $m.name $m.definition --directory=$m.directory --overwrite=$m.overwrite
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _module-names []: nothing -> list { 'use ' | commandline complete | where $it !~ '(.nu|/)$' }
def _definitions []: nothing -> record {
  $config.USER
  | get $.modules $.scripts
  | par-each {|dir|
    glob --no-dir --depth=3 --exclude=$EXCLUDE ($dir | path rejoin ** *.nu)
    | path relative-to $dir
    | wrap value
    | insert description ($dir | str replace $nu.home-dir '~')
  } | flatten --all
  | into completions {
    sort: true
    completion_algorithm: fuzzy
    match_description: true
  }
}
