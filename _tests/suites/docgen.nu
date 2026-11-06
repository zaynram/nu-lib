# Extraction-layer coverage: target resolution, model shape, and failure
# behavior, all against hermetic fixture modules.
use docgen collect
use ../mod.nu *

const FX: path = $FIXTURES | path join docgen

# The sample fixture's collected model.
def sample-model []: nothing -> record {
  collect ($FX | path join sample) | first
}

def "test collect-extracts-module-metadata" []: nothing -> nothing {
  let module = sample-model | get module
  assert equal $module.name sample
  assert equal $module.description "A tiny module exercising every metadata surface the collector extracts."
  assert equal $module.extra_description ""
  assert equal $module.file ($FX | path join sample mod.nu)
}

def "test collect-lists-exports-prefixed-and-sorted" []: nothing -> nothing {
  # exact equality also proves `main` surfaces as the module name and the
  # private `hidden` helper stays invisible
  assert equal (sample-model | get commands.name) [sample "sample greet" "sample total"]
}

def "test collect-normalizes-parameters" []: nothing -> nothing {
  let params = sample-model | get commands | where name == "sample greet" | first | get params
  assert equal $params [
    {
      name: name
      kind: positional
      type: string
      required: true
      short: null
      default: null
      description: "who to greet"
      completion: null
    }
    {
      name: polite
      kind: switch
      type: bool
      required: false
      short: p
      default: null
      description: "use a formal greeting"
      completion: null
    }
    {
      name: punctuation
      kind: named
      type: string
      required: false
      short: null
      default: !
      description: "trailing punctuation"
      completion: null
    }
  ]
}

def "test collect-extracts-io-signatures" []: nothing -> nothing {
  let commands = sample-model | get commands
  assert equal ($commands | where name == "sample greet" | first | get io) [
    {input: nothing, output: string}
  ]
  assert equal ($commands | where name == "sample total" | first | get io) [
    {input: list<int>, output: int}
  ]
}

def "test collect-captures-authored-examples" []: nothing -> nothing {
  let commands = sample-model | get commands
  assert equal ($commands | where name == "sample greet" | first | get examples) [
    {
      description: "greet politely"
      example: "greet world --polite"
      result: "Hello, world!"
    }
  ]
  assert equal ($commands | where name == "sample total" | first | get examples) []
}

def "test collect-carries-search-terms" []: nothing -> nothing {
  let greet = sample-model | get commands | where name == "sample greet" | first
  assert equal $greet.search_terms "hello, salutation"
  assert equal $greet.extra_description "The long form: greetings default to casual unless --polite is given."
}

def "test collect-accepts-file-and-name-targets" []: nothing -> nothing {
  let by_dir = collect ($FX | path join sample)
  assert equal (collect ($FX | path join sample mod.nu)) $by_dir
  $env.NU_LIB_DIRS = [$FX]
  assert equal (collect sample) $by_dir
}

def "test collect-accepts-single-file-module" []: nothing -> nothing {
  let model = collect ($FX | path join single.nu) | first
  assert equal $model.module.name single
  assert equal $model.module.file ($FX | path join single.nu)
  assert equal $model.commands.name ["single shout"]
}

def "test collect-handles-multiple-targets" []: nothing -> nothing {
  let dir = $FX | path join sample
  assert equal (collect $dir $dir | length) 2
}

def "test collect-model-is-nuon-serializable" []: nothing -> nothing {
  # the model doubles as a committed IR snapshot, so it must survive a
  # nuon roundtrip losslessly
  let model = collect ($FX | path join sample)
  assert equal ($model | to nuon | from nuon) $model
}

def "test collect-raises-on-broken-module" []: nothing -> nothing {
  assert error { collect ($FX | path join broken) }
}

def "test collect-raises-on-missing-target" []: nothing -> nothing {
  assert error { collect ($FX | path join nonexistent) }
}

def "test collect-requires-a-target" []: nothing -> nothing {
  assert error { collect }
}

# The nested fixture's collected rows: the module plus its two submodules.
def nested-model []: nothing -> table {
  collect ($FX | path join nested)
}

def "test collect-emits-submodules-as-qualified-rows" []: nothing -> nothing {
  let rows = nested-model
  assert equal ($rows | get module.name) [nested "nested sub" "nested sub leaf"]
  # submodules report no file of their own and inherit the parent's
  assert equal ($rows | get module.file | uniq) [($FX | path join nested mod.nu)]
}

def "test collect-names-nested-exports-as-imported" []: nothing -> nothing {
  # nested exports are callable only after `use nested sub`, and are named accordingly
  assert equal (nested-model | get commands.name) [["nested single shout" "nested top"] [sub "sub inner"] ["leaf tip"]]
}

def "test collect-lists-aliases-and-constants" []: nothing -> nothing {
  let rows = nested-model
  assert equal ($rows | get aliases | each { select name expansion }) [
    [{name: "nested short", expansion: "ls -a"}]
    [{name: "sub al", expansion: inner}]
    []
  ]
  assert equal ($rows | get constants) [[{name: LIMIT, type: int}] [{name: DEEP, type: string}] []]
  # the sample fixture has neither
  assert equal (sample-model | get aliases) []
  assert equal (sample-model | get constants) []
}

def "test collect-strips-linter-and-formatter-directives" []: nothing -> nothing {
  let rows = nested-model
  assert equal ($rows | first | get module.description) "A module whose surface lives in aliases, constants, and submodules."
  assert equal ($rows | first | get commands | where name == "nested top" | first | get description) "A top-level command."
  assert equal ($rows | first | get aliases | first | get description) "Shorthand for a hidden listing."
}

def "test collect-folds-re-exported-modules-into-the-parent" []: nothing -> nothing {
  # `export use` makes a module's commands part of the parent's own surface
  # (`nested single shout` is callable after `use nested`), so it gets no row
  let rows = nested-model
  assert equal ($rows | where module.name =~ single | length) 0
  assert ("nested single shout" in ($rows | first | get commands.name))
}
