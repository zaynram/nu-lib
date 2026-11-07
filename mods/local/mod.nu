# `mods` with the commands that depend on the owner's machine configuration: definition files are found under
# the module and script directories of `conf machine-config user`.
#
# Re-exports the abstract subcommands of `mods` and adds `edit`. The abstract `main` is not re-exported: a
# re-exported `main` takes its module's name (it would appear as `local mod`), so the root barrel declares
# `mods` itself.

# ——— imports ——————————————————————————————————————————————————————————————————

export use ../mod.nu [ define refresh list ]

use error
use path
use completion "into completions"
use conf [ machine-config ]

# ——— constants ————————————————————————————————————————————————————————————————

# Not definitions: nupm's store, tests, backups, and the library's underscore directories (`_docs`, `_tests`).
const EXCLUDE: list<string> = [**/nupm+/** **/tests/** **/tests.nu **/*.bak*/** **/_*/**]

# ——— helpers ——————————————————————————————————————————————————————————————————

# The module and script directories of the user scope.
def definition-dirs []: nothing -> list<path> {
  machine-config user | get $.modules $.scripts | flatten | uniq | where ($it | path exists)
}

# The `.nu` files under the definition directories, with their path relative to the directory they were found in.
def definitions []: nothing -> table<file: path, rel: string> {
  definition-dirs | each {|dir|
    glob ($dir | path rejoin ** *.nu | into glob) --no-dir --depth=3 --exclude=$EXCLUDE
    | sort
    | each {|file| {file: $file rel: ($file | path relative-to $dir)} }
  } | flatten
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Open a module or script definition file by name, or return its path.
#
# The target is matched against the files under the user scope's module and script directories, in order:
# the module name (`<name>/mod.nu` or `<name>.nu`), then the relative path (`conf/machine` or
# `conf/machine.nu`, also as a trailing part such as `machine`), then any part of the relative path.
@category core
export def edit [
  target: string@_definitions # Name of the module or script to target
  --get (-g) # Return the resolved path instead of opening it
]: nothing -> oneof<nothing, path> {
  let defs: table = definitions
  let t: string = $target | str trim --char '/' | str replace --regex '\.nu$' ''
  let tiers: list<closure> = [
    {|d| $d.rel == $'($t)/mod.nu' or $d.rel == $'($t).nu' }
    {|d| let stem: string = $d.rel | str replace --regex '\.nu$' ''; $stem == $t or ($stem ends-with $'/($t)') }
    {|d| $d.rel | str contains $t }
  ]
  let found: path = $tiers
    | each {|tier| $defs | where $tier | get $.0?.file }
    | compact
    | first
    | default {
      error raise $"no definition found for '($target)'" --with={
        kind: not_found
        help: 'definitions are the .nu files under the module and script directories of `conf machine-config user`'
      }
    }
  if $get { return ($found | path expand) }
  use edit
  $found | edit
}

# ——— completions ——————————————————————————————————————————————————————————————

def _definitions []: nothing -> record {
  definition-dirs
  | par-each {|dir|
    glob --no-dir --depth=3 --exclude=$EXCLUDE ($dir | path rejoin ** *.nu)
    | path relative-to $dir
    | wrap value
    | insert $.description ($dir | str replace $nu.home-dir '~')
  } | flatten --all
  | into completions {
    sort: true
    completion_algorithm: fuzzy
    match_description: true
  }
}
