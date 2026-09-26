# Extensions to the builtin `config` commands structured around `user`/`vendor` scoping.

# ——— imports —————————————————————————————————————————————————————————————————

use ../error
use ../path
use ../util editor
use ../completion "into completions"
use /work/ext/bash-env

# ——— constants ————————————————————————————————————————————————————————————————

const LIB: path = if $nu.os-info.name == windows { $nu.home-dir | path join desktop } else { '/work/dev/' }

# Directories of the user scope.
export const USER: record = {
  lib: $LIB
  bin: ($nu.home-dir | path join .local bin)
  home: $nu.home-dir
  config: ($nu.home-dir | path join .config)
  data: ($nu.home-dir | path join .local share)
  cache: ($nu.home-dir | path join .cache)
  state: ($nu.home-dir | path join .local state)
  autoload: $nu.user-autoload-dirs.0?
  modules: ($LIB | path join nu)
  plugins: ($nu.current-exe | path expand | path dirname)
  scripts: /work/bin/
}

# Directories of the vendor scope.
export const VENDOR: record = {
  bin: (if $nu.os-info.name != windows { '/usr/bin' } else { $nu.home-dir | path join AppData Local Microsoft WindowsApps })
  autoload: (if $nu.os-info.name == windows { $nu.vendor-autoload-dirs.1 } else { $nu.vendor-autoload-dirs.2 })
  plugins: ($nu.data-dir | path join plugins (version).version)
  modules: ($USER.data | path join nupm modules)
  scripts: ($USER.data | path join nupm scripts)
}

# Environment variables of the user scope.
const VARS: record = {
  NUPM_HOME: ($USER.data | path join nupm)
  TOPIARY_CONFIG_FILE: ($USER.config | path join topiary languages.ncl)
  TOPIARY_LANGUAGE_DIR: ($USER.config | path join topiary queries)
  GOPATH: ($USER.data | path join go)
  GOBIN: $USER.bin
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def profile-env [
  profile: path = ($nu.home-dir | path join .profile)
]: nothing -> record {
  if not ($profile | path exists) { error make --unspanned $"file not found: '($profile)'" }
  bash-env --return=merge $profile | match ($in.path!? | describe) {
    nothing | list<any> | list<string> => { }
    string => { update $.path! { split row (char esep) } }
  }
}

alias xglob = glob --depth=3 --exclude=[
  **/google-chrome-for-testing/**
  **/nushell/*history*
  **/nushell/autoload/**
  **/helix/runtime/**
  **/helix/grammars/**
  **/helix/queries/**
  **/vale/styles/**
  **/plugins/**
  **/*.yazi/**
  **/.vscode/**
  **/.git*/**
  **/*Cookie*
  **/*Token*/**
  **/*Decode*/**
  **/*Storage*/**
  **/*Cache*/**
  **/*cache*/**
  **/Partitions*/**
  **/Crashpad*/**
  **/*proto*/**
  **/sentry/**
  **/Shared*
  **/Singleton*
  **/Transport*
  **/*DB*/**
  **/*db*/**
  **/logs/**
  **/*.*.*/**
  **/*tokens.*
  **/*Tokens*
  **/*.*bck
  **/*.*shm
  **/*.*wal
  **/*.msgpackz
  **/*.sqlite3
  **/*.wasm
  **/*.bdic
  **/*.db*
  **/*.pem
  **/.org.chromium*
  **/ant-*
  **/LOCK
  **/LOG
  **/DIPS
  **/*cache
  **/InterestGroups
  **/Preferences
  '**/* */**'
  '**/* *'
]

def scope [vendor: bool]: nothing -> record { if $vendor { $VENDOR } else { $USER } }

def homebrew-bin []: nothing -> oneof<nothing, path> {
  match $nu.os-info.name {
    macos => '/opt/homebrew/bin'
    linux => ($nu.home-dir | path basename --replace linuxbrew/.linuxbrew/bin)
  } | if $in != null and ($in | path exists) { }
}

alias find-bin-dirs = glob --no-file --depth=2 --exclude=[**/.vscode-server-insiders/**] ($USER.home | path rejoin ** bin)
alias find-script-dirs = glob --no-file --no-symlink --exclude=[**/_internal/**] ($USER.scripts | path rejoin **)

# Directories a scope contributes to PATH that are not on it yet.
def new-paths [vendor: bool]: nothing -> list<path> {
  if $vendor {
    [$VENDOR.bin $VENDOR.scripts (homebrew-bin)]
  } else {
    [$USER.scripts ...(find-bin-dirs)]
  } | compact
  | difference $env.PATH
}

# Open a resolved file in the editor, or return its expanded path.
def submit [target: oneof<nothing, string> --get]: oneof<nothing, path> -> oneof<nothing, path> {
  # nu-lint-ignore: unused_parameter
  let p: oneof<nothing, path> = $in
  if ($p | is-empty) { error wrap --code=config::unresolved_target $"no items found for target: '($target)'" }
  $p | path expand | if $get { } else { editor }
}

# ——— definitions ——————————————————————————————————————————————————————————————

export use std/config env-conversions

# Show or load a scope's environment variables, PATH additions included.
@category env
export def --env vars [
  --vendor (-v) # Use the vendor scope
  --with (-w): record = {} # Merge these variables in, overriding the scope's own
  --load (-l) # Load the variables into the current process
  --return (-r) # Return the variables as a record (the default when not loading)
]: oneof<nothing, record> -> oneof<nothing, record> {
  let input: record = default {}
  let e: record = if $vendor { {} } else { profile-env | merge $VARS }
    | merge $input
    | merge $with
    | upsert PATH { default $env.path! | prepend (new-paths $vendor) | uniq }
  if $load { $e | load-env }
  if $return or not $load { return $e }
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
  if $p == null { error wrap --code=config::dir::unresolved_target $"no directory named '($target)'" }
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
      0 => { error wrap --code=config::app::unresolved_target $"no config files found for '($target)'" }
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
    $p if ($p | path type) != file => {
      error wrap --code=config::prompt::unresolved_config $"file not found: '($p)'"
    }
    $p if ($p | path parse).extension not-in [toml yaml yml json jsonc] => {
      error wrap --code=config::prompt::unknown_configuration_format $"unexpected configuration file format: '($p)'"
    }
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
  | into completions {match_description: true completion_algorithm: substring}
}
def _app-paths [buffer: string]: nothing -> oneof<record, list> {
  $buffer
  | split row (char space)
  | where $it not-in [config app --path -p] and ($it | is-not-empty)
  | each { prepend $USER.config | path join }
  | where ($it | path type) == dir
  | if ($in | is-empty) { return [] } else {
    let dir: path = $in | first
    let label: string = try { $dir | path relative-to $USER.config } catch { $dir | str replace $nu.home-dir '~' }
    xglob ($dir | path rejoin ** *) --no-dir
    | path relative-to $dir
    | wrap value
    | insert description $label
    | into completions {sort: true match_description: true completion_algorithm: substring}
  }
}
