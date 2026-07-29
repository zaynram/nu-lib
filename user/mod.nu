# nu-lint-ignore-file: positional_to_pipeline, unsafe_dynamic_record_access
# ——— imports ———————————————————————————————————————————————————————————————

use ../error
use ../path
use ../util editor

# ——— constants —————————————————————————————————————————————————————————————

export const bin: path = '/usr/bin/'
export const home: path = $nu.home-dir

const var: record = {
  autoload: $nu.user-autoload-dirs.0?
  config: ($nu.default-config-dir | path dirname)
  data: ($nu.data-dir | path dirname)
  local: ($nu.home-dir | path join .local)
  modules: ($nu.data-dir | path join modules)
  plugins: ($nu.current-exe | path expand | path dirname)
  scripts: ($nu.data-dir | path join scripts)
  common: ($nu.default-config-dir | path join common)
}

export const autoload: path = $var.autoload
export const config: path = $var.config
export const data: path = $var.data
export const local: path = $var.local
export const modules: path = $var.modules
export const plugins: path = $var.plugins
export const scripts: path = $var.scripts
export const common: path = $var.common

const _exclude: list<string> = [**/nupm+/** **/tests/** **/tests.nu]

# ——— helpers ———————————————————————————————————————————————————————————————

alias xglob = glob --depth=4 --exclude=[
  `**/vale/styles/**`
  `**/helix/runtime/**`
  `**/nushell/{autoload/*,history.txt}`
  `**/*.{*bck,*shm,*wal,msgpackz,sqlite3}`
  `**/{logs,Code - Insiders,google-chrome-for-testing}/**`
]

alias nu-glob = do {|then?: closure|
  par-each {|d|
    glob $"($d)/**/*.nu" --no-dir --depth=3 --exclude=$_exclude
    | if $then != null { do --ignore-errors $then $d } else { path relative-to $d }
  } | compact --empty | flatten | uniq
}

# ——— definitions ———————————————————————————————————————————————————————————

# Interact with a script or module definition file.
@category core
export def --env lib [
  target: path@_any-lib-target # The name of the module or script to target
  --get (-g) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, path> {
  let p: path = if $var has $target {
    $var | get $target
  } else if $target != null {
    $var | get modules common scripts | nu-glob { where $it =~ $target } | first
  }
  if $get { return $p } else if $p != null { editor $p } else {
    error wrap --code=usr::lib::unresolved_target ...[
      $"could not find script or module matching '($target)'"
    ]
  }
}

# Interact with an initialization script from an autoload directory.
#
# If the `target` argument is omitted, the items in the directory will be listed.
@category core
export def auto [
  target?: string@_autoload-target # The name of the autoload file to target
  --vendor (-v) # Use the vendor autoload directory
  --get (-g) # Return the resolved path instead of default behavior
]: nothing -> oneof<nothing, path, table> {
  let dir: path = if $vendor { use ../vendor; $vendor } else { $var } | get autoload
  try { mkdir $dir; cd $dir } catch {
    error wrap --code=usr::autoload::internal_error ...[
      "could not resolve autoload directory"
    ]
  }
  let value: oneof<nothing, path> = match {t: $target r: $get} {
    {t: null r: true} => { return $dir }
    {t: null r: false} => { ls --short-names | path select | path expand }
    {t: $t} => { $t | path extension --replace nu | path expand }
  }
  if $value == null {
    error wrap --code=common::user::auto::unresolved_target ...[
      $"unable to resolve autoload script matching '($target)'"
    ]
  } else if $get {
    return $value
  } else {
    editor $value
  }
}

# Edit a non-nushell configuration file.
#
# If no `target` is provided, the eligible target candidates are listed instead.
@category filesystem
export def config [
  # nu-lint-ignore: kebab_case_commands
  target?: path@_config-target # The directory name to search for config files under
  --path (-p): path@_config-path # Exact path (relative to target if provided, otherwise `~/.config`) of a file to edit
  --get (-g) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, table> {
  let cwd: path = [$var.config $target] | compact --empty | path join
  try { mkdir $cwd; cd $cwd } catch {
    error wrap "could not resolve config directory" --code usr::config::unresolved_directory
  }
  if $path != null {
    if not $get { editor $path; return }
    return (pwd | path join $path)
  }
  let files: list = try { xglob **/* --no-dir } | default []
  let count: int = $files | length
  let value: oneof<nothing, path> = if ($files | is-empty) {
    error make --unspanned $"no config files found for '($target)'"
  } else if $count > 1 {
    $files | path truncate --root . | path select | path expand
  } else if $count == 1 {
    $files | first | path expand
  }

  if $value == null {
    error make {
      msg: "could not resolve configuration file"
      label: {text: target span: (metadata $target).span}
    }
  } else if $get {
    return $value
  } else {
    editor $value
  }
}

# Navigate to (or print) a directory value from the `usr` constant.
export def --env main [
  target?: cell-path@_cell-path # Cell-path of the property to retrieve
  --get (-g) # Return the directory path instead of navigating to it
]: nothing -> oneof<nothing, path, record> {
  if $target == null { return $var }
  let dir: oneof<nothing, path> = $var | get --ignore-case --optional $target
  if $get { return $dir } else if $dir != null { cd $dir } else {
    error wrap --code=common::user::dir::invalid_target ...[
      $"the `$var` constant does not have property '($target)'"
    ]
  }
}

# ——— completions ———————————————————————————————————————————————————————————

const _exclude: list<string> = [**/nupm+/** **/tests/** **/tests.nu]
alias nu-glob = do {|then?: closure|
  par-each {|d|
    glob $"($d)/**/*.nu" --no-dir --depth=3 --exclude=$_exclude
    | if $then != null { do --ignore-errors $then $d } else { path relative-to $d }
  } | compact --empty | flatten | uniq
}

def _cell-path []: nothing -> list { $var | columns }
def _any-lib-target []: nothing -> list {
  let cols: list<string> = [modules common scripts]
  $var | select ...$cols | values | nu-glob | append $cols
}
def _autoload-target []: nothing -> list { $var.autoload | nu-glob { path parse | get stem } }
def _config-target []: nothing -> list { xglob $"($var.config)/*" | path basename }
def _config-path [context: string]: nothing -> list {
  $context
  | split words
  | where $it not-in [user config path]
  | par-each { prepend $var.config | path join }
  | where ($it | path type) == dir
  | if ($in | is-empty) { return [] } else {
    let dir: path = $in | first
    xglob $"($dir)/**/*" --no-dir | path relative-to $dir
  }
}
