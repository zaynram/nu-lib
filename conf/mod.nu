# Extensions to the builtin `config` commands structured around `user`/`vendor` scoping.

# ——— imports —————————————————————————————————————————————————————————————————

use error
use completion "into completions"
use path
use edit

export use machine.nu *

# ——— constants ————————————————————————————————————————————————————————————————

const SCRIPT: path = path self machine.nu | path expand --strict

# ——— helpers ——————————————————————————————————————————————————————————————————

alias editor = edit
alias config-dir = try { $env.XDG_CONFIG_DIR! } catch { $nu.default-config-dir | path dirname }

def profile-env [mode: string = user]: nothing -> record {
  let mc: record = machine-config $mode
  match $mode {
    user => ({
      NU_LIB_DIRS: $mc.modules
      PATH: [...$mc.binaries ...$mc.scripts]
    })
    vendor => ({
      NU_PLUGIN_DIRS: $mc.plugins
      NU_LIB_DIRS: [$mc.modules]
      PATH: [$mc.binaries $mc.scripts]
    })
  } | update $.PATH { append $env.path! | uniq }
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

def scope [vendor: bool]: nothing -> record {
  if $vendor { machine-config vendor } else { machine-config user }
}

# Open a resolved file in the editor, or return its expanded path.
def submit [target: oneof<nothing, string> --return]: oneof<nothing, path> -> oneof<nothing, path> {
  # nu-lint-ignore: unused_parameter
  let p: oneof<nothing, path> = $in
  if ($p | is-empty) { error raise --code=config::unresolved_target $"no items found for target: '($target)'" }
  $p | path expand | if $return { } else { editor }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Show or load a scope's environment variables, PATH additions included.
@category env
export def --env vars [
  --vendor (-v) # Use the vendor scope
  --with (-w): record = {} # Merge these variables in, overriding the scope's own
  --load (-l) # Load the variables into the current process
  --return (-r) # Return the variables as a record (the default when not loading)
]: oneof<nothing, record> -> oneof<nothing, record> {
  let input: record = default {} | merge $with
  let e: record = if $vendor { profile-env vendor } else { profile-env user }
  if $load { $input | merge $e | load-env }
  if $return or not $load { return $e }
}

# Navigate to (or return) a directory of a scope; with no target, return them all.
@category filesystem
export def --env dir [
  target?: string@_dirs # Name of the directory to target
  --vendor (-v) # Use the vendor scope
  --return (-r) # Return the path instead of navigating to it
]: nothing -> oneof<nothing, path, record> {
  let s: record = scope $vendor
  if $target == null { return $s }
  let p: oneof<nothing, path> = $s | get --ignore-case --optional $target
  if $p == null { error raise --code=config::dir::unresolved_target $"no directory named '($target)'" }
  $p | if $return { return $in } else { cd $in }
}

# Open an autoload file of a scope; with no target, pick one from a list.
@category filesystem
export def auto [
  target?: string@_auto # Name of the autoload file to target
  --vendor (-v) # Use the vendor scope
  --return (-r) # Return the resolved path instead of opening it
]: nothing -> oneof<nothing, path, table> {
  let dir: path = (scope $vendor).autoload
  try { mkdir $dir; cd $dir } catch {
    error raise --code=config::auto::internal_error "could not resolve autoload directory"
  }
  match {t: $target g: $return} {
    {t: null g: true} => { return $dir }
    {t: null} => { ls --short-names | path select }
    {t: $t} => { $t | path with-extension nu }
  } | submit $target --return=$return
}

# Open an application's configuration file; with no target, list the candidates.
@category filesystem
export def find [
  target?: path@_apps # The directory name to search for config files under
  --path (-p): path@_app-paths # Path of a file to edit, relative to the target directory
  --return (-r) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, path, table> {
  let item: path =  config-dir | if $target != null { path join $target } else { }
  $item | match ($in | path type) {
    file => { submit $target --return=$return | return $in }
    dir => { cd $in }
    _ => { mkdir $in; cd $in }
  }
  if $path != null { $path } else {
    let files: list = try { xglob **/* --no-dir } | default []
    match ($files | length) {
      0 => { error raise --code=config::app::unresolved_target $"no config files found for '($target)'" }
      1 => { $files | first }
      _ => { $files | path truncate --root . | path select }
    }
  } | submit $target --return=$return
}

const PROMPT_EXT: string = '^.+[.]{1}(toml|yaml|yml|json|jsonc)$'

# Refresh the `oh-my-posh` prompt initialization script in the vendor autoload directory.
@category shells
export def prompt [
  --config (-c): path # Prompt configuration file (defaults to `$env.POSH_CONFIG` if set)
]: nothing -> nothing {
  $config | default --empty $env.posh_config!? | if $in == null {
    oh-my-posh init nu
  } else if ($in | path type) != file {
    let msg: string = $"file not found: '($in)'"
    error raise --code=config::prompt::unresolved_config $msg
  } else if $in !~ $PROMPT_EXT {
    let msg: string = $"unexpected configuration file format: '($in)'"
    error raise --code=config::prompt::unknown_configuration_format $msg
  } else {
    oh-my-posh init nu --config=($in)
  }
  let src: path = (scope true).autoload | path join oh-my-posh.nu
  if ($src | path exists) {
    let dst: path = $src | path dirname --replace=(machine-config).autoload
    if not ($dst | path exists) { mv --update $src $dst }
    if $nu.os-info.name == windows {
      open --raw $dst
      | collect { lines | take until { str contains '$_omp_executable upgrade' } | str join (char newline) }
      | save --force $dst
    }
  }
}

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  $env | select $.NU_LIB_DIRS $.NU_PLUGIN_DIRS
  | default [] NU_LIB_DIRS NU_PLUGIN_DIRS
  | merge deep --strategy=prepend {
    NU_LIB_DIRS: $NU_LIB_DIRS
    NU_PLUGIN_DIRS: $NU_PLUGIN_DIRS
  } | update cells { uniq }
  | vars --vendor --load
}

# ——— completions ——————————————————————————————————————————————————————————————

def is-vendor [buffer: string]: nothing -> bool {
  $buffer =~ '(^|\s)(-v|--vendor)(\s|$)'
}

def _dirs [buffer: string]: nothing -> record {
  scope (is-vendor $buffer) | columns | into completions {completion_algorithm: substring}
}
def _auto [buffer: string]: nothing -> record {
  glob (
    (scope (is-vendor $buffer)).autoload
    | path rejoin *.nu
  ) --no-dir
  | path parse
  | select stem parent
  | rename value description
  | into completions {completion_algorithm: substring}
}
def _apps []: nothing -> record {
  xglob (config-dir | path rejoin '*') | wrap description
  | insert value {|row| $row.description | path basename }
  | where value !~ '^[.|_]+\w+'
  | into completions {match_description: true completion_algorithm: substring}
}
def _app-paths [buffer: string]: nothing -> oneof<record, list> {
  let d: path = config-dir
  $buffer | split row (char space)
  | where $it not-in [conf app --path -p] and ($it | is-not-empty)
  | each { prepend $d | path join }
  | where ($it | path type) == dir
  | if ($in | is-empty) { return [] } else {
    let dir: path = $in | first
    let label: string = try { $dir | path relative-to $d } catch {
      $dir | str replace $nu.home-dir '~'
    }
    xglob ($dir | path rejoin ** *) --no-dir
    | where $it !~ '(.nu-lint.toml|.gitignore|.bak|.backup|debug)'
    | path relative-to $dir
    | where $it =~ '^[/|\w|\-|.]+$' and ($it | path parse).stem !~ '\d+'
    | wrap value
    | insert description $label
    | into completions {sort: true match_description: true completion_algorithm: substring}
  }
}
