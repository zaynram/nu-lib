# Utility module for working with Nushell hooks.

# ——— constants ————————————————————————————————————————————————————————————————

const HOOK_TYPES: list = [
  pre_prompt
  pre_execution
  env_change
]

# ——— environment ——————————————————————————————————————————————————————————————

export-env { $env.config.hooks = $env.config.hooks | default [] pre_prompt pre_execution | default {} env_change }

# ——— helpers ——————————————————————————————————————————————————————————————————

def ensure-in-bounds [n: int]: oneof<table, list, nothing> -> int {
  let len: int = $in | default [] | length
  match $n {
    $n if $n >= 0 and $n < $len => $n
    $n if $n < 0 => { $len + $n }
    $n if $n >= $len => { $len - 1 }
  }
}
alias validate-target = do --capture-errors {||
  if $env.config.hooks not-has ($in | into string | split row . | where $it != '$' | first) {
    error make --unspanned $'unknown hook type: ($in)'
  }
}

alias hook-getter = do --capture-errors {|target: oneof<string, cell-path>|
  $target | validate-target
  {|_?: oneof<nothing, int, cell-path>|
    $env.config.hooks | get --ignore-case --optional $target | default [] | if $_ == null { } else { get --optional $_ }
  }
}

alias hook-setter = do {|target: oneof<string, cell-path>|
  $target | validate-target
  {|_: closure| $env.config.hooks = $env.config.hooks | upsert $target $_ }
}

def parse-context []: string -> list<string> {
  split row (char space)
  | compact --empty
  | where not ($it starts-with '--')
  | if ($in | is-empty) { return [] } else { last | split row . }
}

def add-descriptions [
  default: string # Default description
  --value: closure
]: list<any> -> table<value: any, description: oneof<nothing, string>> {
  enumerate
  | reduce --fold=[] {|it acc|
    let x: any = $it.item
    match ($x | describe | split words | first) {
      record if $x has disabled and $x.disabled => null
      record if ($x.name? | is-not-empty) => $x.name
      _ => $default
    } | compact
    | wrap description
    | insert value ($value | default $it)
  }
}
def hook-defaults [--prefix: string]: list -> table<index: int, item: any> {
  default []
  | where ($it | describe) =~ ^record
  | enumerate
  | update item {|row|
    upsert disabled { default false }
    | upsert name {
      default { [$prefix $'unnamed_($row.index)'] | compact | str join '::' }
    }
  }
}

def flatten-hooks [pred?: closure]: [
  nothing -> table<name: string, disabled: bool, condition: closure, code: any, ref: cell-path>
] {
  let predicate: closure = $pred | default { {|| not ($in.disabled? | into bool --relaxed) } }
  $env.config.hooks
  | select --ignore-case --optional ...$HOOK_TYPES
  | compact --empty
  | items {|k v|
    match $k {
      pre_prompt | pre_execution => { $v | hook-defaults --prefix=$k }
      _ => { $v | items {|var ls| $ls | hook-defaults --prefix=$'env.($var)' } | flatten }
    } | update item {|row| insert ref { $k | append $row.index | into cell-path } }
    | get item
  } | flatten --all
  | where $predicate
}
alias invoke = do --env --capture-errors

# ——— definitions ——————————————————————————————————————————————————————————————

# Retreive one or more of the configured Nushell hooks.
@category env
export def --env main [
  target: oneof<string, cell-path>@_hook-types
  # The hook type to target
  index?: int@_hook-indices
  # Retreive the configured hook record at this index
]: nothing -> oneof<nothing, record, table<condition: closure, code: oneof<closure, string>>> {
  invoke (hook-getter $target) $index
}

# Retrieve a value from a hook by reference.
@category env
export def show [
  --strict (-s)
  # Throw an error if the named hook cannot be found
  --default (-d): any = null
  # Value to return when the hook record or property is missing
  name: string@_hook-names
  # The name of the hook record to retrieve the value from
  cell?: cell-path@[name disabled code condition ref]
  # The cell-path of the property to retrieve from the hook record
]: nothing -> oneof<nothing, any> {
  flatten-hooks { $in.name? == $name }
  | match ($in | length) {
    0 if not $strict => { return $default }
    0 => { error make --unspanned $"unable to find hook with name '($name)'" }
    _ if $cell == null => { first | reject ref }
    _ => { first | get --ignore-case --optional $cell | default $default }
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
  } else if ($env.config.hooks | get --ignore-case --optional $ref | is-empty) {
    error make --unspanned $'invalid hook reference: ($ref)'
  } else {
    let value = $overwrite | default { {|| merge $update } }
    $env.config.hooks = $env.config.hooks | update $ref $value
    $env.config.hooks | get --ignore-case $ref
  }
}

# Delete a hook from the environment configuration.
#
# The boolean returned indicates whether any element was removed.
@category env
export def --env del [
  target: cell-path@_hook-types # The type of hook to add the provided configurations to
  index: int@_hook-indices # Remove the configured hook at the specified index
]: nothing -> bool {
  let get: closure = hook-getter $target
  let n: int = invoke $get | length
  invoke (hook-setter $target) {||
    let arr: table = $in | default []
    let idx: int = $arr | ensure-in-bounds $index
    $arr | reject $idx
  }
  $n != (invoke $get | length)
}

# Test a hook closure, optionally with custom arguments.
@category env
export def --wrapped test [
  target: cell-path@_hook-types # The type of hook to add the provided configurations to
  item: cell-path@_hook-elements # Which condition or code closure to run
  ...rest: string # Arguments to pass to the closure
]: nothing -> any {
  match (invoke (hook-getter $target) $item) {
    null => { error make --unspanned $'no closure found for ($target) at ($item)' }
    $elt => { do --capture-errors $elt ...$rest }
  }
}

# Add hook(s) to the current environment configuration.
@category env
export def --env add [
  target: cell-path@_hook-types # The type of hook to add the provided configurations to
  --index (-i): int@_hook-indices = -1 # Insert the record passed as pipeline input at this index (caution: overwrites existing elements)
]: [
  closure -> nothing
  list<closure> -> nothing
  record<condition: closure, code: oneof<string, closure>> -> nothing
  table<condition: closure, code: oneof<string, closure>> -> nothing
] {
  let hooks: list = match ($in | describe | split words | first) { table | list => $in record | closure => [$in] }
  invoke (hook-setter $target) (
    match $index {
      -1 => {|| $in | default [] | append $hooks }
      0 => {|| $in | default [] | prepend $hooks }
      $n => {||
        let arr: list = $in | default [] | enumerate
        let idx: int = $arr | ensure-in-bounds $n
        $arr | reduce --fold=$hooks {|it acc|
          $acc | if $it.index < $idx { prepend $it.item } else { append $it.item }
        }
      }
    }
  )
}

# ——— completions ——————————————————————————————————————————————————————————————

def _hook-types []: nothing -> record {
  {
    options: {
      sort: false
      completion_algorithm: prefix
      case_sensitive: false
    }
    completions: (
      [
        ...($env.config.hooks | columns | where $it not-in [env_change display_output])
        ...($env | columns | where $it !~ ^__\w+ | par-each { prepend env_change | str join . })
      ]
      | sort-by --custom {|a b| $a not-has . and $b has . }
    )
  }
}

def _hook-indices [
  buffer: string
  --value: closure
  --options: record = {}
]: nothing -> oneof<list, record> {
  let ctx: list = $buffer | parse-context
  let str: string = $ctx | prepend '$env.config.hooks' | str join .
  {
    options: (
      {
        sort: false
        match_description: true
        completion_algorithm: substring
        case_sensitive: false
      }
      | merge $options
    )
    completions: (
      $env.config.hooks
      | get --ignore-case --optional ($ctx | into cell-path)
      | if ($in | is-empty) { return [] } else { }
      | add-descriptions $str --value=($value | default {|| get index })
    )
  }
}

def _hook-elements [buffer: string]: nothing -> oneof<list, record> {
  _hook-indices $buffer --value={|x: record<index: int, item: any>|
    if ($x.item | describe) =~ ^record {
      let parts: list = $in
      $x.item | columns | par-each { prepend $parts }
    } | append ($x.index | into string)
    | str join .
  } | flatten value
}

def _hook-refs []: nothing -> oneof<list, record> {
  {
    options: {
      sort: true
      completion_algorithm: substring
      match_description: true
    }
    completions: (
      flatten-hooks
      | select ref name
      | rename --column={ref: value name: description}
      | update value { into string | str replace '$.' '' }
    )
  }
}

def _hook-names []: nothing -> oneof<list, record> {
  {
    options: {
      sort: true
      completion_algorithm: substring
      match_description: true
    }
    completions: (
      flatten-hooks
      | select ref name
      | rename --column={name: value ref: description}
      | update value { into string | str replace '$.' '' }
    )
  }
}
