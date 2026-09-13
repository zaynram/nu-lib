# Extensions to the builtin `config` commands: directories, environment variables, autoload files,
# application configs and the prompt of the user and vendor scopes.

# ——— imports —————————————————————————————————————————————————————————————————

use ../error
use ../path
use ../util [ editor "into completions" ]

# ——— constants ————————————————————————————————————————————————————————————————

const LIB: path = if $nu.os-info.name == windows {
  $nu.home-dir | path join desktop
} else {
  $nu.home-dir | path join library
}

# Directories of the user scope.
export const USER: record = {
  bin: ($nu.home-dir | path join .local bin)
  lib: $LIB
  data: ($nu.data-dir | path dirname)
  home: $nu.home-dir
  autoload: $nu.user-autoload-dirs.0?
  modules: ($LIB | path join nushell)
  config: ($nu.default-config-dir | path dirname)
  plugins: ($nu.current-exe | path expand | path dirname)
  scripts: ($nu.data-dir | path join scripts)
  cache: ($nu.cache-dir | path dirname)
}

# Directories of the vendor scope.
export const VENDOR: record = {
  bin: (if $nu.os-info.name == windows {
    $nu.home-dir | path join AppData Local Microsoft WindowsApps
  } else {
    '/opt/homebrew/bin/'
  })
  autoload: (if $nu.os-info.name == windows {
    $nu.vendor-autoload-dirs.1
  } else {
    $nu.vendor-autoload-dirs.2
  })
  plugins: ($nu.data-dir | path join plugins (version).version)
  modules: ($nu.data-dir | path basename --replace nupm/modules)
  scripts: ($nu.data-dir | path basename --replace nupm/scripts)
}

# Environment variables of the user scope.
const VARS: record = {
  XDG_CONFIG_HOME: $USER.config
  XDG_DATA_HOME: $USER.data
  PNPM_HOME: ($USER.data | path join pnpm)
  NUPM_HOME: ($USER.data | path join nupm)
  TOPIARY_CONFIG_FILE: ($USER.config | path join topiary languages.ncl)
  TOPIARY_LANGUAGE_DIR: ($USER.config | path join topiary queries)
  GOPATH: ($USER.data | path join go)
  GO_BIN: $USER.bin
}

# ——— helpers ——————————————————————————————————————————————————————————————————

alias xglob = glob --depth=3 --exclude=[
  **/*.yazi/**
  `**/{.vscode,.git*,plugins,vale/styles}/**`
  `**/helix/{runtime,grammars,queries}/**`
  `**/{logs,Code - Insiders,google-chrome-for-testing}/**`
  `**/nushell/{autoload/*,history.txt}`
  **/.nu-lint.toml
  `**/*.{*bck,*shm,*wal,msgpackz,sqlite3,wasm}`
]

def scope [vendor: bool]: nothing -> record { if $vendor { $VENDOR } else { $USER } }

# Directories a scope contributes to PATH that are not on it yet.
def new-paths [vendor: bool]: nothing -> list<path> {
  if $vendor { [$VENDOR.bin $VENDOR.scripts] } else {
    glob --no-file --depth=2 --exclude=[**/.vscode-server-insiders/**] ($USER.home | path rejoin ** bin)
    | append (glob --no-file --no-symlink --exclude=[**/_internal/**] ($USER.scripts | path rejoin **))
  } | difference $env.PATH
}

# Open a resolved file in the editor, or return its expanded path.
def submit [target: oneof<nothing, string>, --get]: oneof<nothing, path> -> oneof<nothing, path> { # nu-lint-ignore: unused_parameter
  let p: oneof<nothing, path> = $in
  if ($p | is-empty) { error wrap --code=config::unresolved_target $"no items found for target: '($target)'" }
  $p | path expand | if $get { } else { editor }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Show or load a scope's environment variables, PATH additions included.
@category env
export def --env vars [
  --vendor (-v) # Use the vendor scope
  --with (-w): record = {} # Merge these variables in, overriding the scope's own
  --load (-l) # Load the variables into the current process
  --show (-s) # Return the variables as a record (the default when not loading)
]: oneof<nothing, record> -> oneof<nothing, record> {
  let input: record = default {}
  let e: record = if $vendor { {} } else { $VARS }
    | merge $input
    | merge $with
    | upsert PATH { default $env.PATH | prepend (new-paths $vendor) }
  if $load { $e | load-env }
  if $show or not $load { return $e }
}

# Navigate to (or return) a directory of a scope; with no target, return them all.
@category filesystem
export def --env dir [
  target?: string@_dirs # Name of the directory to target
  --vendor (-v) # Use the vendor scope
  --get (-g) # Return the path instead of navigating to it
]: nothing -> oneof<nothing, path, record> {
  let s: record = scope $vendor
  if $target == null { return $s }
  let p: oneof<nothing, path> = $s | get --ignore-case --optional $target
  if $p == null { error wrap --code=config::dir::invalid_target $"no directory named '($target)'" }
  if $get { $p } else { cd $p }
}

# Open an autoload file of a scope; with no target, pick one from a list.
@category filesystem
export def auto [
  target?: string@_auto # Name of the autoload file to target
  --vendor (-v) # Use the vendor scope
  --get (-g) # Return the resolved path instead of opening it
]: nothing -> oneof<nothing, path, table> {
  let dir: path = (scope $vendor).autoload
  try { mkdir $dir; cd $dir } catch {
    error wrap --code=config::auto::internal_error "could not resolve autoload directory"
  }
  match {t: $target g: $get} {
    {t: null g: true} => { return $dir }
    {t: null} => { ls --short-names | path select }
    {t: $t} => { $t | path with-extension nu }
  } | submit $target --get=$get
}

# Open an application's configuration file; with no target, list the candidates.
@category filesystem
export def app [
  target?: path@_apps # The directory name to search for config files under
  --path (-p): path@_app-paths # Path of a file to edit, relative to the target directory
  --get (-g) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, path, table> {
  let item: path = [$USER.config $target] | compact --empty | path join
  $item | match ($in | path type) {
    file => { submit $target --get=$get | return $in }
    dir => { cd $in }
    _ => { mkdir $in; cd $in }
  }
  if $path != null { $path } else {
    let files: list = try { xglob **/* --no-dir } | default []
    match ($files | length) {
      0 => { error make --unspanned $"no config files found for '($target)'" }
      1 => { $files | first }
      _ => { $files | path truncate --root . | path select }
    }
  } | submit $target --get=$get
}

# Refresh the `oh-my-posh` prompt initialization script in the vendor autoload directory.
@category shells
export def prompt [
  --config (-c): path # Prompt configuration file (defaults to `$env.POSH_CONFIG` if set)
]: nothing -> nothing {
  match ($config | default --empty $env.POSH_CONFIG?) {
    null => { oh-my-posh init nu }
    $p if ($p | path type) != file => { error make --unspanned $"file not found: '($p)'" }
    $p if ($p | path parse).extension not-in [toml yaml yml json jsonc] => { error make --unspanned $"invalid configuration file: '($p)'" }
    $p => { oh-my-posh init nu --config=($p) }
  }
  let f: path = $VENDOR.autoload | path join oh-my-posh.nu
  $f | run ($VENDOR.autoload | path basename --replace require-tty) | ignore
  if $nu.os-info.name == windows {
    open --raw $f
    | collect { lines | take until { str contains '$_omp_executable upgrade' } | str join (char newline) }
    | save --force $f
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def is-vendor [buffer: string]: nothing -> bool { $buffer =~ '(^|\s)(-v|--vendor)(\s|$)' }

def _dirs [buffer: string]: nothing -> record {
  scope (is-vendor $buffer) | columns | into completions {completion_algorithm: substring}
}
def _auto [buffer: string]: nothing -> record {
  glob ((scope (is-vendor $buffer)).autoload | path rejoin '*.nu') --no-dir
  | path parse
  | select stem parent
  | rename value description
  | into completions {completion_algorithm: substring}
}
def _apps []: nothing -> record {
  xglob ($USER.config | path rejoin '*')
  | wrap description
  | insert value {|row| $row.description | path basename }
  | into completions {match_description: true, completion_algorithm: substring}
}
def _app-paths [buffer: string]: nothing -> oneof<record, list> {
  $buffer
  | split row (char space)
  | where $it not-in [config app --path -p] and ($it | is-not-empty)
  | par-each { prepend $USER.config | path join }
  | where ($it | path type) == dir
  | if ($in | is-empty) { return [] } else {
    let dir: path = $in | first
    let label: string = try { $dir | path relative-to $USER.config } catch { $dir | str replace $nu.home-dir '~' }
    xglob ($dir | path rejoin ** *) --no-dir
    | path relative-to $dir
    | wrap value
    | insert description $label
    | into completions {sort: true, match_description: true, completion_algorithm: substring}
  }
}
