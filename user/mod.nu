# nu-lint-ignore-file: positional_to_pipeline, unsafe_dynamic_record_access
# ——— imports ———————————————————————————————————————————————————————————————

use ../error
use ../path
use ../util editor

# ——— constants —————————————————————————————————————————————————————————————

export const bin: path = $nu.home-dir | path join .local bin
export const lib: path = $nu.home-dir | path join library
export const data: path = $nu.data-dir | path dirname
export const home: path = $nu.home-dir
export const autoload: path = $nu.user-autoload-dirs.0?
export const modules: path = $lib | path join nushell
export const config: path = $nu.default-config-dir | path dirname
export const plugins: path = $nu.current-exe | path expand | path dirname
export const scripts: path = $nu.data-dir | path join scripts
export const cache: path = $nu.cache-dir | path dirname

const _exclude: list<string> = [**/nupm+/** **/tests/** **/tests.nu]

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  load-env {
    XDG_CONFIG_HOME: ($env.XDG_CONFIG_HOME? | default $config)
    XDG_DATA_HOME: ($env.XDG_DATA_HOME? | default $data)
    PNPM_HOME: ($data | path join pnpm)
    NUPM_HOME: ($data | path join nupm)
    TOPIARY_CONFIG_FILE: ($config | path join topiary languages.ncl)
    TOPIARY_LANGUAGE_DIR: ($config | path join topiary queries)
    GOPATH: ($data | path join go)
    GOBIN: $bin
  }
}

# ——— helpers ———————————————————————————————————————————————————————————————

alias xglob = glob --depth=3 --exclude=[
  `**/*.yazi/**`
  `**/plugins/**`
  `**/vale/styles/**`
  `**/helix/runtime/**`
  `**/nushell/{autoload/*,history.txt}`
  `**/*.{*bck,*shm,*wal,msgpackz,sqlite3,wasm}`
  `**/{logs,Code - Insiders,google-chrome-for-testing}/**`
]

alias nu-glob = do {|then?: closure|
  par-each {|d|
    glob $"($d)/**/*.nu" --no-dir --depth=3 --exclude=$_exclude
    | if $then != null { do --ignore-errors $then $d } else { path relative-to $d }
  } | compact --empty | flatten | uniq
}

alias vars = do --ignore-errors { (scope variables | where name == '$user').0?.value }

# ——— definitions ———————————————————————————————————————————————————————————

# Interact with a script or module definition file.
@category core
export def --env lib [
  target: path@_any-lib-target # The name of the module or script to target
  --get (-g) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, path> {
  let p: path = vars | get --ignore-case --optional $target
    | default { [$modules $scripts] | nu-glob { where $it =~ $target } | first }
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
  let dir: path = if $vendor { use ../vendor autoload; $autoload } else { $autoload }
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
  let cwd: path = [$config $target] | compact --empty | path join
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
  if $target == null { return (vars) }
  let dir: oneof<nothing, path> = vars | get --ignore-case --optional $target
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

def _cell-path []: nothing -> list { vars | columns }
def _any-lib-target []: nothing -> list {
  [$modules $scripts] | nu-glob | append [modules scripts]
}
def _autoload-target []: nothing -> list { $autoload | nu-glob { path parse | get stem } }
def _config-target []: nothing -> list { xglob $"($config)/*" | path basename }
def _config-path [context: string]: nothing -> list {
  $context
  | split words
  | where $it not-in [user config path]
  | par-each { prepend $config | path join }
  | where ($it | path type) == dir
  | if ($in | is-empty) { return [] } else {
    let dir: path = $in | first
    xglob $"($dir)/**/*" --no-dir | path relative-to $dir
  }
}
