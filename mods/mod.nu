# Utilities for interacting with Nushell modules.

# ——— imports ——————————————————————————————————————————————————————————————————

use ../vendor modules
use ($modules | path join docgen)

# ——— constants ————————————————————————————————————————————————————————————————

const SHORT: table = [
  [prefix segments replace];
  [null $nu.home-dir ~]
  [$.mods_home? null @]
  [$.nupm_home? modules '$']
]
const RE: record = {
  omit: '^(prelude|[_]{1}\w+|\w+\s{1}extern)$'
}

# ——— utilities ————————————————————————————————————————————————————————————————

def default-include-modules [
  --include-overlays
]: oneof<nothing, table<name: string, commands: list, file: string>> -> table<name: string, commands: list, file: string> {
  default { scope modules }
  | where (
    $it.name !~ $RE.omit
    and ($it.file | path exists)
    and (scope commands | get decl_id | intersect $it.commands.decl_id | is-not-empty)
    and ($include_overlays or (overlay list).name not-has $it.name)
  ) | uniq-by module_id
}

def preserve-serialized-closure []: closure -> list<string> {
  view source $in
  | str replace --all --regex '^\{\|*\s*|\s*\}$' ''
  | lines
  | str trim --left
  | append ['']
}

alias build-mods-refs = par-each --keep-order {|row|
  if $row.prefix? != null { $env | get --ignore-case --optional $row.prefix }
  | if ($row.segments? | is-not-empty) { append $row.segments } else { default [] }
  | path join
  | wrap find
  | insert replace $row.replace
}

def module-file-shorthand []: [
  nothing -> table<find: string, replace: string>
  path -> oneof<nothing, record<find: string, replace: string>>
] {
  let p: oneof<nothing, path> = $in
  $env.mods_refs?
  | default { $SHORT | reverse | build-mods-refs }
  | if $p == null { } else { where $p has $it.find | first }
}

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  $env.mods_hist = history session
  $env.mods_home = $env.mods_home?
    | default { $env.NU_LIB_DIRS | where ($it | path exists) | first }
    | path expand --strict
  $env.mods_used = list --short
  $env.mods_refs = module-file-shorthand
  # Wrapped with `do` to ensure `$env.mods_used` does not pick up this import invocation.
  do --capture-errors --env {
    const module_command_regex: string = '\s*(use|hide|overlay\s+(use|hide))\s+(?<name>[\w\-]+)\s*'
    alias recent-module-commands = try {
      let after: datetime = 'a minute ago' | date from-human
      history --long | where session_id == $env.mods_hist and start_timestamp > $after and command =~ $module_command_regex
    } catch { [] }
    use ../hook add; [
      [name condition code];
      [
        `mods::use_or_hide::update-mods_used`
        {|| $env has mods_used and (recent-module-commands | is-not-empty) }
        {|| list --update }
      ]
    ] | add pre_prompt
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Define a module inline and save it to a file.
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
  $block | preserve-serialized-closure | try { %save --force --progress $path } catch { error make --unspanned 'unable to save module definition' }
  return $path
}

# List the modules loaded in the current session.
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
]: nothing -> oneof<list<string>, table<module: record, commands: table>, table<name: string, description: string, location: path>> {
  let ls: table = if $name != null { scope modules | where name == $name } else { default-include-modules --include-overlays=$overlays }
  if $update { $env.mods_used = $ls.name }
  $ls | if $short { get name } else {
    docgen collect ...($in.file | where { path exists })
    | update $.module.description {|row| append $row.module.extra_description? | compact --empty | str join (char newline) }
    | update $.module.file {|row|
      let p: path = if $in ends-with mod.nu { path dirname } else { }
      let s: oneof<nothing, record> = $p | module-file-shorthand
      $p | if $absolute or $s == null { } else { str replace $s.find $s.replace }
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
export def --env main [
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
  $in | match ($in | describe | split words | first) {
    closure if $name == null => { error make --unspanned 'name is required when defining a new module' }
    closure => { define $name $in }
    nothing if not $all and $name == null and ($env.mods_used | is-not-empty) => { $env.mods_used }
    nothing => { list --short --overlays=$all $name }
    record if $in not-has definition and ($in | is-not-empty) => {
      items {|name definition|
        if ($name | is-empty) or ($definition | describe) != closure { return }
        define $name $definition
      } | compact
    }
    record => {
      let m: record = default $name name | default $env.mods_home directory | default false overwrite
      if $m.definition == null { error make --unspanned 'module definition is required' }
      if $m.name == null { error make --unspanned 'name is required when defining a new module' }
      define $m.name $m.definition --directory=$m.directory --overwrite=$m.overwrite
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _module-names []: nothing -> list { 'use ' | commandline complete | where $it !~ '(.nu|/)$' }
