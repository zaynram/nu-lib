# Various definitions aimed at enhancing developer experience with shell tooling.

# nu-lint-ignore-file: positional_to_pipeline, unsafe_dynamic_record_access

# ——— imports ———————————————————————————————————————————————————————————————

use ../error
use ../path
use ../util [ editor fix-path "into completions" ]

# ——— constants —————————————————————————————————————————————————————————————

export const bin: path = $nu.home-dir | path join .local bin
export const lib: path = if $nu.os-info.name == windows {
  $nu.home-dir | path join desktop
} else {
  $nu.home-dir | path join library
}
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

# ——— helpers ———————————————————————————————————————————————————————————————

alias xglob = glob --depth=3 --exclude=[
  **/*.yazi/**
  `**/{.vscode,.git*,plugins,vale/styles}/**`
  `**/helix/{runtime,grammars,queries}/**`
  `**/{logs,Code - Insiders,google-chrome-for-testing}/**`
  `**/nushell/{autoload/*,history.txt}`
  **/.nu-lint.toml
  `**/*.{*bck,*shm,*wal,msgpackz,sqlite3,wasm}`
]

alias nu-glob = do {|then?: closure|
  par-each {|d|
    let p: path = $d | fix-path
    glob $"($p)/**/*.nu" --no-dir --depth=3 --exclude=$_exclude
    | if $then != null { do --ignore-errors $then $p } else { path relative-to $p }
  } | flatten --all | compact | uniq
}

alias vars = do --ignore-errors { (scope variables | where name == '$user').0?.value }

# ——— definitions ———————————————————————————————————————————————————————————

# Consume or initialize the user environment variables.
export def --env env [
  --with (-w): record = {
    XDG_CONFIG_HOME: $config
    XDG_DATA_HOME: $data
    PNPM_HOME: ($data | path join pnpm)
    NUPM_HOME: ($data | path join nupm)
    TOPIARY_CONFIG_FILE: ($config | path join topiary languages.ncl)
    TOPIARY_LANGUAGE_DIR: ($config | path join topiary queries)
    GOPATH: ($data | path join go)
    GO_BIN: $bin
  }
  # Merge these environment variables into the record, overwriting any existing values
  --load (-l)
  # Load the environment into the current process, if not done so already
  --show (-s)
  # Return the user environment, as a record
]: oneof<record, nothing> -> oneof<nothing, record> {
  let e: record = default {} | merge $with | upsert PATH { default $env.PATH | prepend (path) }
  if $load { $e | load-env }
  if $show or not $load { return $e }
}

# Return a list of PATH directories satisfying a condition.
#
# If no predicate is provided, directories in the current environment's PATH will be excluded.
export def path [
  pred?: closure # Predicate to filter the elements included in the output list
  --all (-a) # Include all directories (cannot be combined with a predicate)
]: nothing -> list {
  glob --no-file --depth=2 --exclude=[**/.vscode-server-insiders/**] ($home | fix-path ** bin)
  | append (glob --no-file --no-symlink --exclude=[**/_internal/**] ($scripts | fix-path **))
  | if $all { } else if $pred != null { where $pred } else { difference $env.PATH }
}

# Interact with a script or module definition file.
@category core
export def --env lib [
  target: path@_any-lib-target # The name of the module or script to target
  --get (-g) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, path> {
  let p: path = vars | get --ignore-case --optional $target
    | default { [$modules $scripts] | nu-glob { where $it has $target } | first }
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
  --path (-p): path@_config-path # Path of a file to edit, relative to `$target`
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

alias replace-home = str replace $nu.home-dir '~'

def _cell-path []: nothing -> oneof<record, list> {
  vars | columns | into completions {completion_algorithm: substring}
}
def _any-lib-target []: nothing -> oneof<record, list> {
  [
    ...($modules | nu-glob | wrap value | insert description ($modules | replace-home))
    ...($scripts | nu-glob | wrap value | insert description ($scripts | replace-home))
  ] | into completions {
    sort: true
    completion_algorithm: fuzzy
    match_description: true
  }
}
def _autoload-target []: nothing -> oneof<record, list> {
  $autoload
  | nu-glob { path parse | rename --column={stem: value parent: description} }
  | reject extension
  | into completions {completion_algorithm: substring}
}
def _config-target []: nothing -> oneof<record, list> {
  xglob ($config | fix-path *)
  | wrap description
  | insert value {|row| $row.description | path basename }
  | into completions {
    match_description: true
    completion_algorithm: substring
  }
}
def _config-path [context: string]: nothing -> oneof<record, list> {
  $context
  | split words
  | where $it not-in [user config path]
  | par-each { prepend $config | path join }
  | where ($it | path type) == dir
  | if ($in | is-empty) { return [] } else {
    let dir: path = $in | first
    let label: string = try { $dir | path relative-to $config } catch { $dir | replace-home }
    xglob ($dir | fix-path ** *) --no-dir
    | path relative-to $dir
    | wrap value
    | insert description $label
    | into completions {
      sort: true
      match_description: true
      completion_algorithm: substring
    }
  }
}
