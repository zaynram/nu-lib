# Utility module for working with Nushell hooks.

use error
use std/util structure
use std/iter flat-map
use completion "into completions"

# ——— constants ————————————————————————————————————————————————————————————————

const HOOK_TYPES: list = [
  pre_prompt
  pre_execution
  env_change
  display_output
  command_not_found
]

# ——— types ————————————————————————————————————————————————————————————————————

type CodeType = oneof<string, closure>
type OptStr = oneof<nothing, string>
type OptBool = oneof<nothing, bool>

type HookData = oneof<record<name: string>, record<name: OptStr, code: CodeType>, record<name: OptStr, condition: closure, code: CodeType, disabled: OptBool>>
type HookType = oneof<HookData, CodeType>
type HookInfo = oneof<record<ref: cell-path name: string, condition: oneof<nothing, closure>, code: CodeType, disabled: OptBool>, record<ref: cell-path, name: nothing, code: CodeType, disabled: bool>>

# ——— environment ——————————————————————————————————————————————————————————————

# On the nightlies this library targets Nushell refills these keys itself whenever `$env.config.hooks` is set (`{}`
# and a `reject` come back filled, `null` is rejected), so this block is a no-op there; it stays as a guard for a
# Nushell that stops doing so.
export-env {
  $env.config.hooks = $env.config.hooks
    | default [] pre_prompt pre_execution
    | default {} env_change
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# No `def` precedes this raise, so its code has no command segment (`hook::not_found`), as a raise in `main` would.
alias validate-target = do --capture-errors {||
  let key: cell-path;
  if ($env.config.hooks | get --optional --ignore-case $key) != null { return }
  error raise $"no hook configured at '($key)'" --kind not_found
}

alias hook-getter = do --capture-errors {|target: cell-path|
  $target | validate-target
  let hook: any = $env.config.hooks | get --ignore-case $target
  {|_?| $hook | if $_ == null { } else { get --optional $_ } }
}

alias hook-setter = do {|target: cell-path|
  {|_: closure| $env.config.hooks = $env.config.hooks | upsert $target $_ }
}

# The hook type (first member) of a hook reference, e.g. `env_change` for `$.env_change.PWD`.
def hook-type []: cell-path -> string { into string | split row . | skip | first }

# Does a reference name one hook: an entry of a hook type's list (`$.pre_prompt.0`, `$.env_change.PWD.0`) or a
# single-valued type (`$.display_output`), whose value is a record, closure or string? A hook type's list
# (`$.pre_prompt`, `$.env_change.PWD`) and the `env_change` record are not one hook.
def names-one-hook []: cell-path -> bool {
  let ref: cell-path = $in
  let entry: bool = ($ref | split cell-path | length) > 1 or ($ref | hook-type) in [display_output command_not_found]
  $entry and ($env.config.hooks | get --optional --ignore-case $ref | describe) =~ '^(record|closure|string)'
}

# Does a target name a hook list to add to: a hook type (`$.pre_prompt`, also the single-valued types) or an
# `env_change` variable (`$.env_change.PWD`)? An entry of a list (`$.pre_prompt.0`) is not one.
def names-hook-list []: cell-path -> bool {
  match ($in | split cell-path | get value) {
    [$type] => ($type in $HOOK_TYPES)
    [env_change _] => true
    _ => false
  }
}

# A text target such as `env_change.PWD` as a cell-path (one member per dot-separated part).
def into-target []: oneof<string, cell-path> -> cell-path {
  if ($in | describe) == string { split row . | into cell-path } else { }
}

def add-descriptions [
  default: string # Default description
  --value: closure
  --display: closure
]: oneof<record, list<any>> -> table<value: any, description: oneof<nothing, string>> {
  append [] | enumerate | each {|it|
    let x: any = $it.item
    match ($x | describe | str replace --regex '<.*' '') {
      record if $x has disabled and $x.disabled => null
      record if ($x.name? | is-not-empty) => $x.name
      _ => $default
    } | wrap description
    | insert value { $it | if $value != null { do --capture-errors $value } else { } }
  } | compact description
  | flatten --all value
  | if $display != null { insert display {|row| $row.value | do --ignore-errors $display } } else { }
}

def hook-defaults [prefix: string]: [
  nothing -> list<any>
  oneof<string, list, table> -> list<HookInfo>
] {
  # `append []` rather than std-rfc's `into list`: the latter turns a record into a key/value table.
  append [] | enumerate | each {|row|
    let ref: cell-path = $prefix | split row '.' | append $row.index | into cell-path
    let name: string = $"($prefix)[($row.index)]"
    $row.item | match ($in | describe | str replace --regex '<.*' '') {
      string | closure => { wrap code | merge {name: $name disabled: false condition: {|| is-enabled $ref } ref: $ref} }
      record => { default false disabled | default $ref ref | default $name name }
    }
  } | compact
}

def flatten-hooks [
  pred?: closure
  --only: cell-path
  --include: list<string> = []
]: nothing -> list<HookType> {
  # `condition` is optional per hook, so it is not part of the declared row type: with
  # `enforce-runtime-annotations` a declared column missing from any row is a runtime type mismatch.
  $env.config.hooks
  | select --ignore-case --optional ...$HOOK_TYPES
  | compact --empty
  | transpose type items
  | flat-map {|row|
    get $.items | match $row.type {
      command_not_found | display_output => {
        let code: oneof<nothing, closure, string>;
        let ref: cell-path = [$row.type] | into cell-path
        [{name: $row.type disabled: ($code == null) condition: {|| is-enabled $ref } code: $code ref: $ref}]
      }
      env_change => { transpose name value | flat-map {|x| $x.value | hook-defaults $'($row.type).($x.name)' } }
      _ => { hook-defaults $row.type }
    }
  } | match ($pred | describe) {
    closure => { where $pred }
    nothing if $only != null => { where ref == $only }
    nothing if $include != [] => { where name in $include }
    _ => { where not $it.disabled }
  }
}

alias invoke = do --env --capture-errors $in

# ——— definitions ——————————————————————————————————————————————————————————————

# Retrieve one or more of the configured Nushell hooks.
@category env
export def --env main [
  target: oneof<string, cell-path>@_hook-types
  # The hook type to target
  index?: int@_hook-indices
  # Retrieve the configured hook record at this index
]: nothing -> oneof<nothing, HookData, list<HookData>> {
  hook-getter ($target | into-target) | invoke $index
}

# Check whether a hook is enabled or not (useful for `$.disabled` conditions).
@category util
export def is-enabled [
  ref?: cell-path@_hook-refs
  # The cell-path of the hook record to retrieve the value from
  --name (-n): string@_hook-names
  # Check the hook by name (useful for custom definitions when ref is inaccessible)
  --strict (-s)
  # Throw an error if the hook cannot be resolved
]: nothing -> bool {
  if $ref != null {
    not (show $ref disabled --strict=$strict --default=false)
  } else if $name != null {
    not (list $name --strict=$strict | get $.0?.disabled!? | default false)
  } else {
    error raise 'a ref or --name is required' --with={
      kind: invalid_argument
      help: "pass the hook's cell-path or its --name"
    }
  }
}

# Execute a closure in a temporary environment with a modified hook.
# ---
# If pipeline input is provided, it will be loaded into the closure environment. When the hook cannot be
# resolved, the closure still runs (without any modification) unless `--strict` is given. `display_output` and
# `command_not_found` hold a single closure or string, not a record: targeting one raises
# `hook::edit::invalid_argument` (replace them with `hook edit --overwrite` instead); so does a reference to a
# hook list rather than one of its entries (`$.pre_prompt`, `$.env_change.PWD`).
export def with [
  modification: record
  # Merged into the hook record for the duration of the closure, e.g. `{disabled: true}`
  closure: closure
  # The closure to execute with or without the hook enabled
  --root(-r): directory
  # The directory to invoke the closure from (navigated to after the hook modification)
  --hook (-h): cell-path@_hook-refs
  # The cell-path of the hook record to retrieve the value from
  --name (-n): string@_hook-names
  # Check the hook by name (useful for custom definitions when ref is inaccessible)
  --strict (-s)
  # Throw an error if the hook cannot be resolved
]: oneof<nothing, record> -> oneof<nothing, any, error> {
  let vars: record = default {}
  if $name == null and $hook == null {
    error raise 'either a name or reference is required' --kind invalid_argument
  }
  let ref: oneof<nothing, cell-path> = $hook
    | default (if $name != null { list $name --strict=$strict | get $.0?.ref })
  if $ref != null and ($env.config.hooks | get --optional --ignore-case $ref) != null {
    edit $ref --update=$modification | ignore
  } else if $strict {
    let target: string = if $hook != null { $"at '($hook)'" } else { $"named '($name)'" }
    error raise $"no hook ($target)" --kind not_found
  }
  if $root != null and ($root | path type) == dir { cd $root }
  with-env $vars $closure
}

# Retrieve the reference for a hook entry from its name.
@category util
export def reference [
  name: string@_hook-names
  # The name of the hook to retrieve the reference for
  --strict (-s)
  # Throw an error if the hook is not found for the provided name (instead of returning `null`)
]: nothing -> oneof<nothing, cell-path, error> { list $name --strict=$strict | get $.0?.ref }

# Retrieve a value from a hook by reference.
@category env
export def show [
  ref: cell-path@_hook-refs
  # The cell-path of the hook record to retrieve the value from
  cell?: cell-path@_cell-paths
  # The cell-path of the property to retrieve from the hook record
  --strict (-s)
  # Throw an error if the named hook cannot be found
  --default (-d): any = null
  # Value to return when the hook record or property is missing
  --raw (-r)
  # Disable serialization of closures (useful for manual testing; otherwise use `hook test`)
]: nothing -> oneof<nothing, HookType> {
  let found: list = flatten-hooks --only=$ref
    | if $raw { } else {
      let stringify: closure = {|| if $in == null { } else { to nuon --serialize --raw-strings | str trim --char='"' } }
      $in | each {|| upsert code $stringify | upsert condition $stringify }
    }
  if $found == [] and $strict {
    error raise $"no hook at '($ref)'" --with={
      kind: not_found
      labels: [{text: reference span: (metadata $ref).span}]
    } | do $in
  }
  $found | get $.0? | if $cell == null { } else { get --optional=(not $strict) $cell } | default $default
}

# Retrieve one or more hooks by name, as a table.
@category env
export def list [
  ...names: string@_hook-names
  # The name(s) of hook record(s) to retrieve the value(s) for
  --strict (-s)
  # Throw an error if the named hook(s) cannot be found
]: nothing -> oneof<list<any>, list<HookType>> {
  let found: list = flatten-hooks --include=$names
  if $found == [] and $strict {
    let listed: string = $names | each {|n| $"'($n)'" } | str join ', '
    error raise $"no hook named ($listed)" --with={
      kind: not_found
      labels: [{text: 'name(s)' span: (metadata $names).span}]
    } | do $in
  }
  $found
}

# Interact with properties of configured hooks.
#
# The reference names one hook: an entry of a hook list (`$.pre_prompt.0`, `$.env_change.PWD.0`) or a single-valued
# type; the list itself (`$.pre_prompt`, `$.env_change.PWD`) is refused (`hook add` appends to it).
@category env
export def --env edit [
  ref: cell-path@_hook-refs
  # The full path of the hook to alter
  --overwrite: oneof<string, closure, record<condition: closure, code: oneof<string, closure>>>
  # Value to replace the referenced hook with
  --update: record
  # An update record to merge into an existing hook record; `display_output` and `command_not_found` hold a single
  # closure or string, so they take `--overwrite` only
]: nothing -> oneof<HookData, CodeType> {
  if $overwrite == null and $update == null {
    error raise 'no overwrite value or update record was given' --with={
      kind: invalid_argument
      help: 'pass --overwrite or --update'
    }
  } else if ($env.config.hooks | get --optional --ignore-case $ref) == null {
    error raise $"no hook at '($ref)'" --kind not_found
  } else if not ($ref | names-one-hook) {
    error raise $"'($ref)' is a list of hooks, not one hook" --with={
      kind: invalid_argument
      help: 'reference one entry (`$.pre_prompt.0`, `$.env_change.PWD.0`); `hook add` appends to the list'
    }
  } else if $overwrite == null and ($ref | hook-type) in [display_output command_not_found] {
    error raise $"the hook at '($ref)' holds a single closure or string, not a record" --with={
      kind: invalid_argument
      help: 'display_output and command_not_found are replaced with --overwrite, not merged with --update'
    }
  } else {
    # `update` calls a closure argument, so the overwrite value is wrapped: a closure is stored, not its result.
    # A bare closure/string hook becomes a `{code}` record before an update record is merged into it.
    let value: closure = if $overwrite != null { {|| $overwrite } } else {
      {|| let h = $in; (if ($h | describe) starts-with record { $h } else { {name: null code: $h} }) | merge $update }
    }
    $env.config.hooks = $env.config.hooks | update $ref $value
    $env.config.hooks | get --ignore-case $ref
  }
}

# Delete a hook from the environment configuration; returns whether anything was removed.
@category env
export def --env del [
  ref: cell-path@_hook-refs
  # The full path of the hook to remove
]: nothing -> bool {
  if ($env.config.hooks | get --optional --ignore-case $ref) == null { return false }
  $env.config.hooks = $env.config.hooks | reject --ignore-case $ref
  return true
}

# Test a hook closure, optionally with custom arguments.
@category env
export def --wrapped test [
  ref: cell-path@_hook-refs
  # Which condition or code closure to run
  --condition (-c)
  # Test the condition evaluation instead of the code execution
  --input (-i): any = null
  # Pass this value as input to the code or condition
  ...rest: string
  # Arguments to pass to the closure
]: nothing -> oneof<nothing, any> {
  if $condition { $.condition } else { $.code }
  | show --raw $ref $in
  | default {
    let part: string = if $condition { 'condition' } else { 'code' }
    error raise $"no hook ($part) at '($ref)'" --with={
      kind: not_found
      labels: [{text: reference span: (metadata $ref).span}]
    } | do $in
  }
  | let h: oneof<string, closure>
  | match ($in | describe) {
    closure => ($input | do --capture-errors $h ...$rest)
    string => (
      $input | to nuon --serialize --raw-strings
      | ^$nu.current-exe --stdin --no-config-file --commands $"from nuon | ($h)"
    )
  }
}

# Add hook(s) to the current environment configuration.
#
# The target is a hook type (`$.pre_prompt`) or an `env_change` variable (`$.env_change.PWD`); an entry of a list
# (`$.pre_prompt.0`) is refused (`hook edit` changes one).
@category env
export def --env add [
  target: cell-path@_possible-hook-types
  # The type of hook to add the provided configurations to
  value?: oneof<string, closure, record>
  # The configuration to add to the hook type (appended to pipeline input if present)
  --index (-i): int@_hook-indices = -1
  # Insert before this index (negative counts from the end; the default appends). `display_output` and
  # `command_not_found` hold a single value: the (last) new value replaces it and the index does not apply.
  --dedupe (-d)
  # Skip hook records whose name is already registered (enabled or disabled)
]: oneof<nothing, list<HookType>> -> nothing {
  # bound first: only the first pipeline of the block receives the input
  let given: oneof<nothing, list<HookType>> = $in
  if not ($target | names-hook-list) {
    error raise $"'($target)' is not a hook type or an env_change variable" --with={
      kind: invalid_argument
      help: 'add to a hook type (`$.pre_prompt`) or an env_change variable (`$.env_change.PWD`); `hook edit` changes one entry'
    }
  }
  let hooks: list = $given | if $value != null { append $value } else { } | match $in {
      [_ ..] if $dedupe => {
        let names: list<string> = flatten-hooks {|| true } | get $.name
        $in | where ($it | describe) !~ ^record or $it.name? not-in $names
      }
      [_ ..] => { }
      _ => { return null }
    } | compact
  if ($target | hook-type) in [display_output command_not_found] {
    # Wrapped: `upsert` would call a closure value instead of storing it.
    let value: any = $hooks | last
    $env.config.hooks = $env.config.hooks | upsert $target {|_| $value }
    return
  }
  hook-setter $target | invoke {||
    let all: list = append []
    let idx: int = $index
      | if $in >= 0 { } else { $in + ($all | length) + 1 }
      | prepend 0 | math max
    [...($all | take $idx) ...$hooks ...($all | skip $idx)]
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

const _options = {
  sort: false
  match_description: true
  completion_algorithm: substring
  case_sensitive: false
}

def _hook-types []: nothing -> record {
  [
    ...($env.config.hooks | reject --optional env_change | columns)
    ...($env.config.hooks.env_change | columns | where $it !~ ^__\w+ | str replace --regex '^' 'env_change.')
  ]
  | sort-by --custom {|a b| $a not-has . and $b has . }
  | into completions {
    sort: false
    completion_algorithm: prefix
    case_sensitive: false
  }
}

def _possible-hook-types []: nothing -> record {
  [
    ...($env.config.hooks | reject --optional env_change | columns)
    ...($env | columns | where $it !~ ^__\w+ | str replace --regex '^' 'env_change.')
  ]
  | sort-by --custom {|a b| $a not-has . and $b has . }
  | into completions {
    sort: false
    completion_algorithm: prefix
    case_sensitive: false
  }
}

def _hook-indices [
  buffer: string
  --value: closure
  --options: record = {}
]: nothing -> oneof<list, record> {
  let cell: cell-path = structure $buffer
    | where kind == string
    | get text
    | split row '.'
    | flatten
    | into cell-path
  let full: string = $cell | into string | str replace '$.' '$env.config.hooks.'
  let post: closure = $value | default { {|| $in.index } }
  $env.config.hooks | get --ignore-case --optional $cell
  | if ($in | is-empty) { return [] } else { add-descriptions $full --value=$post }
  | into completions {
    sort: ($options.sort? | default false)
    match_description: ($options.match_description? | default true)
    completion_algorithm: ($options.completion_algorithm? | default 'substring')
    case_sensitive: ($options.case_sensitive? | default false)
  }
}

def _hook-refs []: nothing -> oneof<list, record> {
  flatten-hooks
  | select ref name
  | rename --column={ref: value name: description}
  | update value { into string | str replace '$.' '' }
  | into completions {
    sort: true
    completion_algorithm: substring
    match_description: true
  }
}

def _hook-names []: nothing -> oneof<list, record> {
  _hook-refs | update completions { rename --column={value: description description: value} }
}

def _cell-paths []: nothing -> oneof<list, record> {
  [
    [value display description];
    [name '$.name?' 'oneof<nothing, string>']
    [disabled '$.disabled?' 'oneof<nothing, bool>']
    [code '$.code' 'oneof<string, closure()>']
    [condition '$.condition?' 'oneof<nothing, closure()>']
    [ref '$.ref?' 'oneof<nothing, cell-path>']
  ] | into completions {
    sort: true
    completion_algorithm: substring
    match_description: false
  }
}
