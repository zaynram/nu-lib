# ——— constants ————————————————————————————————————————————————————————————————

const HOOK_TYPES: list = [
  pre_prompt
  pre_execution
  env_change
  display_output
  command_not_found
]

# ——— helpers ——————————————————————————————————————————————————————————————————

def ensure-in-bounds [n: int]: oneof<table, list, nothing> -> int {
  let len: int = $in | default [] | length
  match $n {
    $n if $n >= 0 and $n < $len => $n
    $n if $n < 0 => { $len + $n }
    $n if $n >= $len => { $len - 1 }
  }
}

def build-proxy [target: oneof<string, cell-path>]: list<any> -> record<get: closure, set: closure, ls: list> {
  let rest: list = $in
  let ct: int = $rest | length
  match ($target | parse 'env_change.{name}' | get --optional name | first) {
    null => {
      get: {|_: oneof<nothing, cell-path> = null|
        $env.config.hooks
        | get --ignore-case --optional $target
        | default []
        | if $_ != null { get --ignore-case --optional $_ } else { }
        | first
      }
      set: {|_: closure|
        $env.config.hooks = $env.config.hooks | upsert $target $_
      }
      ls: $rest
    }
    $var => {
      get: {|_: oneof<nothing, cell-path> = null|
        $env.config.hooks.env_change
        | get --ignore-case --optional $var
        | default []
        | if $_ != null { get --ignore-case --optional $_ } else { }
        | first
      }
      set: {|_: closure|
        $env.config.hooks.env_change = $env.config.hooks.env_change | upsert $var $_
      }
      ls: (
        match $ct {
          2 => $rest
          1 => { $env | get --optional $var | append $rest }
          0 => { 0..1 | par-each { $env | get --ignore-case --optional $var } }
        }
      )
    }
  }
}

alias invoke = do --capture-errors

# ——— definitions ——————————————————————————————————————————————————————————————

# Interact with the configured Nushell hooks.
#
# If no `--add` index is provided, the default behavior will append the pipeline input record to the target array.
# If no pipeline input is provided, the default behavior will return the hooks table for the `$target`.
export def --env --wrapped main [
  target: oneof<string, cell-path>@_hook-types # The hook type to target
  --run (-r): cell-path@_hook-elements # Run one of the condition or code closures for a hook
  --del (-d): int@_hook-indices # Remove the configured hook at the specified index
  --put (-p): int@_hook-indices = -1 # Insert the record passed as pipeline input at this index (caution: overwrites existing elements)
  --get (-g): int@_hook-indices # Retreive the configured hook record at this index
  ...rest: string # Parameters to spread to the `--test` closure
]: [
  record<condition: closure, code: oneof<string, closure>> -> nothing
  nothing -> oneof<nothing, record, table<condition: closure, code: oneof<closure, string>>>
] {
  if $run != null and $del != null { error make --unspanned '`--test` and `--del` cannot be combined' }
  if $in != null and ($run != null or $del != null) { error make --unspanned 'hook insertion cannot be combined with flags except `--add`' }
  if ($target | split row .).0? not-in $HOOK_TYPES { error make --unspanned $'unknown hook type: ($target)' }
  let proxy: record = $rest | build-proxy $target
  match $in {
    null if $run != null => {
      invoke $proxy.get $run
      | match $in {
        null => { error make --unspanned $'no closure found for ($target) at ($run)' }
        $elt => { do --capture-errors $elt ...$proxy.ls }
      }
    }
    null if $del != null => {
      do --capture-errors $proxy.set {||
        let arr: table = default []
        let idx: int = $arr | ensure-in-bounds $del
        $arr | reject $idx
      }
    }
    null if $run == null and $del == null => {
      invoke $proxy.get $get
    }
    $h if $put == -1 => { invoke $proxy.set {|| append $h } }
    $h if $put == 0 => { invoke $proxy.set {|| prepend $h } }
    $h => {
      do --capture-errors $proxy.set {||
        let arr: table = default []
        let idx: int = $arr | ensure-in-bounds $put
        $arr | insert $idx $h
      }
    }
  }
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
