# Extraction-layer coverage: target resolution, model shape, and failure
# behavior, all against hermetic fixture modules.
use docgen
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

# The message of the error `action` raises.
def error-of [action: closure]: nothing -> string {
  try { do $action; '' } catch {|e| $e.msg }
}

def "test collect-raises-on-broken-module" []: nothing -> nothing {
  let msg = error-of { collect ($FX | path join broken) }
  let use = $"use ($FX | path join broken | to nuon)"
  assert str contains $msg $"docgen: failed to collect after `($use)`" 'names the failing import'
  assert str contains $msg 'nu::parser::unclosed_delimiter' "carries the child's stderr"
}

def "test collect-raises-on-missing-target" []: nothing -> nothing {
  let target = $FX | path join nonexistent
  assert equal (error-of { collect $target }) $"docgen: target does not exist: ($target)" 'a missing path'
  let use = $"use ('zz-no-such-module' | to nuon)"
  assert str contains (error-of { collect zz-no-such-module }) $"docgen: failed to collect after `($use)`" 'an unknown name'
}

def "test collect-requires-a-target" []: nothing -> nothing {
  assert equal (error-of { collect }) 'docgen collect: at least one module target is required' 'no targets'
}

def "test main-delegates-to-collect" []: nothing -> nothing {
  let dir = $FX | path join sample
  assert equal (docgen $dir) (collect $dir) 'same model'
}

def "test collect-treats-dot-targets-and-existing-names-as-paths" []: nothing -> nothing {
  let by_dir = collect ($FX | path join sample)
  cd ($FX | path join sample)
  assert equal (collect .) $by_dir '`.` is the current directory'
  with-sandbox {|ctx|
    cp --recursive ($FX | path join sample) $ctx.code
    mkdir ($ctx.code | path join sample inner)
    cd ($ctx.code | path join sample inner)
    let up = collect .. | first | get module
    assert equal [$up.name $up.file] [sample ($ctx.code | path join sample mod.nu)] '`..` is the parent directory'
  }
  cd $FX
  assert equal (collect sample) $by_dir 'a bare name that exists on disk is a path'
}

# A module at `<root>/<rel>` with one command, `name`.
def write-module [root: path, rel: path, name: string]: nothing -> path {
  let dir: path = $root | path join $rel
  mkdir $dir
  $"# A fixture.\nexport def ($name) []: nothing -> string { 'x' }\n" | save ($dir | path join mod.nu)
  $dir | path join mod.nu
}

def "test collect-resolves-missing-slash-targets-through-the-lib-dirs" []: nothing -> nothing {
  with-sandbox {|ctx|
    let file: path = write-module ($ctx.code | path join lib) zzpkg/sub from-lib
    $env.NU_LIB_DIRS = [($ctx.code | path join lib)]
    cd $ctx.code
    let model = collect zzpkg/sub | first
    assert equal $model.module.file $file 'found under a lib dir'
    assert equal $model.commands.name ['sub from-lib'] 'its commands'
    assert equal (collect zzpkg/sub/mod.nu | first | get module.file) $file 'a mod.nu path too'
    let root = collect completion/local | first | get module
    assert equal [$root.name $root.file] [local ($ROOT | path join completion local mod.nu)] 'library modules from outside the repository root'
  }
}

def "test collect-prefers-existing-paths-over-the-lib-dirs" []: nothing -> nothing {
  with-sandbox {|ctx|
    write-module ($ctx.code | path join lib) zzpkg/sub from-lib | ignore
    let local: path = write-module ($ctx.code | path join here) zzpkg/sub from-here
    $env.NU_LIB_DIRS = [($ctx.code | path join lib)]
    cd ($ctx.code | path join here)
    let model = collect zzpkg/sub | first
    assert equal [$model.module.file $model.commands.name] [$local ['sub from-here']] 'the path that exists wins'
  }
}

def "test collect-resolves-names-through-the-nupm-modules-directory" []: nothing -> nothing {
  with-sandbox {|ctx|
    let module = $ctx.code | path join modules zz-nupm-fixture
    mkdir $module
    "# Installed with nupm.\nexport def hello []: nothing -> string { 'hi' }\n" | save ($module | path join mod.nu)
    $env.NUPM_HOME = $ctx.code
    let model = collect zz-nupm-fixture | first
    assert equal $model.module.file ($module | path join mod.nu) 'found under $NUPM_HOME/modules'
    assert equal $model.commands.name ['zz-nupm-fixture hello'] 'its commands'
  }
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
  let names = nested-model | get commands | each { get name }
  assert equal $names [["nested single shout" "nested top"] [sub "sub inner"] ["leaf tip"]] 'names per row'
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

# The shapes fixture's collected rows.
def shapes-model []: nothing -> table {
  collect ($FX | path join shapes)
}

def "test collect-keeps-every-signature-of-an-overloaded-command" []: nothing -> nothing {
  let multi = shapes-model | first | get commands | where name == 'shapes multi' | first
  assert equal $multi.io [{input: int output: string} {input: nothing output: string}] 'one io row per signature'
  assert equal ($multi.params | get name) [loud] 'parameters come from one signature'
}

def "test collect-emits-submodules-without-commands-of-their-own" []: nothing -> nothing {
  let rows = shapes-model
  assert equal ($rows | get module.name) [shapes 'shapes consts' 'shapes holder' 'shapes holder inner' 'shapes odd name'] 'every submodule gets a row'
  let consts = $rows | where module.name == 'shapes consts' | first
  assert equal [$consts.commands $consts.constants] [[] [{name: C type: int}]] 'only constants'
  let holder = $rows | where module.name == 'shapes holder' | first
  assert equal [$holder.commands $holder.constants] [[] []] 'only a submodule'
  let inner = $rows | where module.name == 'shapes holder inner' | first
  assert equal ($inner.commands | get name) ['inner deep'] 'named as imported with `use holder inner`'
}

def "test collect-quotes-submodule-names-in-the-child-imports" []: nothing -> nothing {
  let odd = shapes-model | where module.name == 'shapes odd name' | first
  assert equal ($odd.commands | get name) ['odd name hi'] 'a name with a space'
}
