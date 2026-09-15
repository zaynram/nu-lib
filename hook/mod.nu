# Utility module for working with Nushell hooks.

use ../util [ "into completions" contains-key dispatch ]
use std/util structure
use std/iter flat-map

# ——— constants ————————————————————————————————————————————————————————————————

const HOOK_TYPES: list = [
  pre_prompt
  pre_execution
  env_change
  display_output
  command_not_found
]

const TEST_PATH: path = $nu.temp-dir | path join test-hook.nu

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  $env.config.hooks = $env.config.hooks
    | default [] pre_prompt pre_execution
    | default {} env_change
}

# ——— helpers ——————————————————————————————————————————————————————————————————

alias validate-target = do --capture-errors {||
  let key: cell-path;
  if ($env.config.hooks | contains-key $key) { return }
  error make --unspanned $'hook not found: ($key)'
}

alias hook-getter = do --capture-errors {|target: cell-path|
  $target | validate-target
  let hook: any = $env.config.hooks | get --ignore-case $target
  {|_?| $hook | if $_ == null { } else { get --optional $_ } }
}

alias hook-setter = do {|target: cell-path|
  {|_: closure| $env.config.hooks = $env.config.hooks | upsert $target $_ }
}

def add-descriptions [
  default: string # Default description
  --value: closure
  --display: closure
]: oneof<record, list<any>> -> table<value: any, description: oneof<nothing, string>> {
  append [] | enumerate | reduce --fold=[] {|it acc|
    let x: any = $it.item
    match ($x | describe | split words | first) {
      record if $x has disabled and $x.disabled => null
      record if ($x.name? | is-not-empty) => $x.name
      _ => $default
    } | wrap description
    | insert value { $it | if $value != null { do --capture-errors $value } else { } }
  } | compact $.description
  | flatten --all value
  | if $display != null { insert display {|row| $row.value | do --ignore-errors $display } } else { }
}

def hook-defaults [prefix: string]: [
  nothing -> list<any>
  oneof<string, list, table> -> table<ref: cell-path, code: oneof<string, closure>, name: string, disabled: bool>
] {
  # `append []` rather than std-rfc's `into list`: the latter turns a record into a key/value table.
  append [] | enumerate | each {|row|
    let ref: cell-path = $prefix | split row '.' | append $row.index | into cell-path
    let name: string = $"($prefix)[($row.index)]"
    $row.item | dispatch type --pipe {
      'string|closure': {|| wrap code | merge {name: $name disabled: false condition: {|| is-enabled $ref } ref: $ref} }
      record: {|| default false disabled | default $ref ref | default $name name }
    }
  } | compact
}

def flatten-hooks [
  pred?: closure
  --only: cell-path
  --include: list<string> = []
]: nothing -> table<name: string, disabled: bool, code: oneof<string, closure>, ref: cell-path> {
  # `condition` is optional per hook, so it is not part of the declared row type: with
  # `enforce-runtime-annotations` a declared column missing from any row is a runtime type mismatch.
  $env.config.hooks
  | select --ignore-case --optional ...$HOOK_TYPES
  | compact --empty
  | transpose type items
  | flat-map {|row|
    get $.items | match $row.type {
      env_change => { transpose name value | flat-map {|x| $x.value | hook-defaults $'($row.type).($x.name)' } }
      _ => { hook-defaults $row.type }
    }
  } | match ($pred | describe) {
    closure => { where $pred }
    nothing if $only != null => { where ref == $only }
    nothing if $include != [] => { where name in $include }
    _ => { where not disabled }
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
]: nothing -> oneof<nothing, record, table> {
  hook-getter $target | invoke $index
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
  $ref | default $name | dispatch type --pipe {
    cell-path: {|| show $in disabled --strict=$strict --default=false }
    string: {||
      flatten-hooks --include=[$in]
      | get --optional=(not $strict) $.0.disabled
      | default false
    }
  } | not $in
}

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
]: nothing -> oneof<nothing, any> {
  flatten-hooks --only=$ref
  | if $raw { } else {
    let stringify: closure = {|| if $in == null { } else { to nuon --serialize --raw-strings | str trim --char='"' } }
    $in | each {|| upsert code $stringify | upsert condition $stringify }
  } | if $in == [] and $strict {
    error make {
      msg: 'no hook exists at the provided reference'
      code: 'internal::hook::invalid_cell-path_reference'
      label: {text: reference span: (metadata $ref).span}
    }
  } else {
    get --optional 0 | if $cell == null { } else { get --optional=(not $strict) $cell }
  } | default $default
}

# Retrieve one or more hooks by name, as a table.
@category env
export def list [
  ...names: string@_hook-names
  # The name(s) of hook record(s) to retrieve the value(s) for
  --strict (-s)
  # Throw an error if the named hook(s) cannot be found
]: nothing -> oneof<list<any>, table> {
  flatten-hooks --include=$names | if $in != [] or not $strict { } else {
    error make {
      msg: 'no hook exists with the provided name(s)'
      code: 'internal::hook::unresolved_name'
      label: {text: 'name(s)' span: (metadata $names).span}
    }
  }
}

# Interact with properties of configured hooks.
@category env
export def --env edit [
  ref: cell-path@_hook-refs
  # The full path of the hook to alter
  --overwrite: oneof<string, closure, record<condition: closure, code: oneof<string, closure>>>
  # Value to replace the referenced hook with
  --update: record
  # An update record to merge into an existing hook record
]: nothing -> record {
  if $overwrite == null and $update == null {
    error make --unspanned 'no overwrite value or update record was given'
  } else if ($env.config.hooks | contains-key --not $ref) {
    error make --unspanned $'invalid hook reference: ($ref)'
  } else {
    let value = $overwrite | default { {|| merge $update } }
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
  if ($env.config.hooks | contains-key --not $ref) { return false }
  $env.config.hooks = $env.config.hooks | reject --ignore-case $ref
  true
}

# Test a hook closure, optionally with custom arguments.
@category env
export def --wrapped test [
  ref: cell-path@_hook-refs
  # Which condition or code closure to run
  --condition (-c)
  # Test the condition evaluation instead of the code execution
  --input (-i): any = null
  # Pass this value as input to the code or condition (only supported for closures, not strings)
  ...rest: string
  # Arguments to pass to the closure
]: nothing -> oneof<nothing, any> {
  if $condition { $.condition } else { $.code }
  | show --raw $ref $in
  | if $in == null {
    error make {
      msg: $'no hook (if $condition { "condition" } else { "code" }) exists at the provided reference'
      code: 'internal::hook::invalid_cell-path_reference'
      label: {text: reference span: (metadata $ref).span}
    }
  } else {
    let h: oneof<string, closure> | (
      dispatch type --errors=true --exec {
        closure: {||
          $input | do --capture-errors $h ...$rest
        }
        string: {||
          [
            '#!/usr/bin/env -S nu --stdin --no-config-file'
            $'def main []: ($input | describe) -> any { ($h) }'
          ] | save --raw --force $TEST_PATH
          $input | run --full-reparse $TEST_PATH ...$rest
        }
      }
    )
  }
}

# Add hook(s) to the current environment configuration.
@category env
export def --env add [
  target: cell-path@_possible-hook-types
  # The type of hook to add the provided configurations to
  --index (-i): int@_hook-indices = -1
  # Insert the pipeline input before this index (negative counts from the end; the default appends)
]: [
  closure -> nothing
  list<closure> -> nothing
  record -> nothing
  table -> nothing
] {
  let hooks: list = append []
  hook-setter $target | invoke {||
    let list: list = append []
    let idx: int = if $index < 0 { ($list | length) + $index + 1 } else { $index } | [0 $in] | math max
    [...($list | take $idx) ...$hooks ...($list | skip $idx)]
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
    ...($env.config.hooks | columns | where $it != env_change)
    ...($env.config.hooks.env_change | columns | where $it !~ ^__\w+ | each { prepend env_change | str join . })
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
    ...($env.config.hooks | columns | where $it != env_change)
    ...($env | columns | where $it !~ ^__\w+ | each { prepend env_change | str join . })
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
    | reduce --fold=[] {|it acc| $it | split row '.' | prepend $acc }
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
