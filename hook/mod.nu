# ——— constants ————————————————————————————————————————————————————————————————

const HOOK_TYPES: list = [
  pre_prompt
  pre_execution
  env_change
  display_output
  command_not_found
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
alias parse-variable = try { parse 'env_change.{name}' | into record | get name }
alias validate-target = do --capture-errors {||
  if $env.config.hooks not-has ($in | into string | split row . | where $it != '$' | first) {
    error make --unspanned $'unknown hook type: ($in)'
  }
}

alias hook-getter = do --capture-errors {|target: oneof<string, cell-path>|
  $target | validate-target
  {|_: oneof<nothing, string, cell-path>|
    $env.config.hooks
    | get --ignore-case --optional $target
    | default []
    | if $_ == null or ($in | is-empty) {
      return $in
    } else if $in has $_ {
      get $_
    } else if $in has name and $in.name has $_ {
      where name == $_ | first
    }
  }
}

alias hook-setter = do {|target: oneof<string, cell-path>|
  $target | validate-target
  {|_: closure| $env.config.hooks = $env.config.hooks | upsert $target $_ }
}

def test-args [
  target: oneof<string, cell-path>
]: list<any> -> list<any> {
  let rest: list = $in
  let ct: int = $rest | length
  match ($target | parse-variable) {
    null => $rest
    $x if $ct == 2 => $rest
    $x if $ct == 1 => [...$rest ($env | get --ignore-case --optional $x)]
    $x => [null ($env | get --ignore-case --optional $x)]
  }
}

alias invoke = do --env --capture-errors

# ——— definitions ——————————————————————————————————————————————————————————————

# Retreive one or more of the configured Nushell hooks.
export def --env main [
  target: oneof<string, cell-path>@_hook-types # The hook type to target
  index?: int@_hook-indices # Retreive the configured hook record at this index
]: nothing -> oneof<nothing, record, table<condition: closure, code: oneof<closure, string>>> {
  invoke (hook-getter $target) $index
}

# Delete a hook from the environment configuration.
#
# The boolean returned indicates whether any element was removed.
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
export def --wrapped test [
  target: cell-path@_hook-types # The type of hook to add the provided configurations to
  item: cell-path@_hook-elements # Which condition or code closure to run
  ...rest: string # Arguments to pass to the closure
]: nothing -> any {
  match (invoke (hook-setter $target) $item) {
    null => { error make --unspanned $'no closure found for ($target) at ($item)' }
    $elt => { do --capture-errors $elt ...(test-args $target) }
  }
}

# Add hook(s) to the current environment configuration.
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
        $arr | reduce --fold=$hooks {|it acc| $acc | if $it.index < $idx { prepend $it.item } else { append $it.item } }
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

def _hook-indices [context: string --pipe: closure]: nothing -> record {
  let type: oneof<nothing, string> = $context
    | split row (char space)
    | compact --empty
    | where not ($it starts-with '--')
    | last
  let cell: oneof<nothing, cell-path> = $type | try { split row . | into cell-path }
  {
    options: {
      sort: false
      match_description: true
      completion_algorithm: substring
      case_sensitive: false
    }
    completions: (
      $env.config.hooks
      | get --ignore-case --optional $cell
      | default []
      | enumerate
      | if $pipe != null {
        get index | par-each $pipe | flatten
      } else {
        flatten item
        | select --optional index name
        | rename --column={index: value name: description}
        | update description {|row| default --empty { $type | split row . | prepend ['$env' config hooks] | append $row.value | str join . } }
      }
    )
  }
}

def _hook-elements [context: string]: nothing -> record {
  _hook-indices --pipe={|n: int| [code condition] | par-each { prepend $n | str join . } } $context
}
