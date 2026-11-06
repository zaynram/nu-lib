# Extensions to the builtin `config` commands structured around `user`/`vendor` scoping.

# ——— imports —————————————————————————————————————————————————————————————————

use error
use completion "into completions"
use path
use edit
use style

export use machine.nu *

# ——— helpers ——————————————————————————————————————————————————————————————————

alias editor = edit
alias config-dir = try { $env.XDG_CONFIG_DIR! } catch { $nu.default-config-dir | path dirname }

# A scope's variables: its directories first, then the entries the environment already has.
def profile-env [mode: string = user --no-file]: nothing -> record {
  let mc: record = machine-config $mode --no-file=$no_file
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

def scope [vendor: bool]: nothing -> record {
  if $vendor { machine-config vendor } else { machine-config user }
}

# Open a resolved file in the editor, or return its expanded path.
def submit [target: oneof<nothing, string> --return]: oneof<nothing, path> -> oneof<nothing, path> {
  let p: oneof<nothing, path> = $in
  if ($p | is-empty) { error raise $"no items found for target '($target)'" --kind not_found }
  $p | path expand | if $return { } else { editor }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Show or load a scope's environment variables (`NU_LIB_DIRS`, `PATH`, and `NU_PLUGIN_DIRS` for the vendor scope).
#
# Each list variable is the entries the environment already has (PATH-like text inherited from a parent process
# counts as its entries), preceded by those of the piped record's entries and the scope's directories (in that
# order) that it lacks. Existing entries keep their positions, so loading
# never drops or reorders a directory and loading twice changes nothing. Other piped variables are kept, and
# `--with` values replace anything else.
@category env
export def --env vars [
  --vendor (-v) # Use the vendor scope
  --with (-w): record = {} # Merge these variables in, overriding the scope's own
  --load (-l) # Load the variables into the current process
  --return (-r) # Return the variables as a record (the default when not loading)
  --no-file # Ignore the machine override file: the defaults and `--with` only
]: oneof<nothing, record> -> oneof<nothing, record> {
  let input: record = $in | default {}
  let scope: record = profile-env (if $vendor { 'vendor' } else { 'user' }) --no-file=$no_file
  let combined: record = $scope
    | record each {|key dirs|
      # Inherited PATH-like text is split: Nushell converts `PATH` and `NU_LIB_DIRS` to lists, not `NU_PLUGIN_DIRS`.
      let existing: list = $env | get --optional --ignore-case $key | default []
        | if ($in | describe) == string { split row (char esep) } else { }
      let added: list = $input | get --optional $key | default [] | append $dirs | uniq | where $it not-in $existing
      {$key: ($added | append $existing)}
    }
  let e: record = $input | merge $combined | merge $with
  if $load { $e | load-env }
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
  let p: oneof<path, list<path>> = $s
    | get --ignore-case --optional $target
    | default {
      error raise $"no directory named '($target)'" --kind not_found --advice $"directories: ($s | columns | str join ', ')"
    }
  if $return { return $p }
  if ($p | describe) =~ '^list' {
    error raise $"'($target)' is a list of directories" --kind invalid_argument --advice 'pass --return to get the list instead of navigating'
  }
  cd $p
}

# Open an autoload file of a scope; with no target, pick one from a list.
@category filesystem
export def auto [
  target?: string@_auto # Name of the autoload file to target
  --vendor (-v) # Use the vendor scope
  --return (-r) # Return the resolved path instead of opening it
]: nothing -> oneof<nothing, path, table> {
  let dir: path = (scope $vendor).autoload
  try { mkdir $dir; cd $dir } catch {|e|
    $e | error raise $"could not create or enter the autoload directory '($dir)'" --kind io
  }
  match {t: $target g: $return} {
    {t: null g: true} => { return $dir }
    {t: null} => { ls --short-names | path select }
    {t: $t} => { $t | path with-extension nu }
  } | submit $target --return=$return
}

# Open an application's configuration file; with no target, list the candidates.
#
# The target is a file or directory under the config directory (`$env.XDG_CONFIG_DIR`, else the parent of
# Nushell's). A directory with one config file resolves to it; with several, pick one interactively. `--path`
# names a file under the target directory, which need not exist yet.
@category filesystem
export def find [
  target?: path@_apps # The directory name to search for config files under
  --path (-p): path@_app-paths # Path of a file to edit, relative to the target directory
  --return (-r) # Return the constructed path instead of opening it
]: nothing -> oneof<nothing, path, table> {
  let item: path =  config-dir | if $target != null { path join $target } else { }
  # The arm receives the match input (the path), which `error raise` does not take: hence `null |`.
  $item | match ($in | path type) {
    file => { submit $target --return=$return | return $in }
    dir => { cd $in }
    _ => { null | error raise $"no config directory or file named '($target)'" --kind not_found }
  }
  if $path != null { $path } else {
    let files: list = try { xglob **/* --no-dir } | default []
    match ($files | length) {
      0 => { error raise $"no config files found for '($target)'" --kind not_found --advice 'pass --path to name a file to create' }
      1 => { $files | first }
      _ => { $files | path truncate --root . | path select }
    }
  } | submit $target --return=$return
}

const PROMPT_EXT: string = '^.+[.]{1}(toml|yaml|yml|json|jsonc)$'

# Refresh the `oh-my-posh` prompt initialization script and move it to the user autoload directory.
#
# `oh-my-posh init nu` writes the script into the vendor autoload directory; it replaces any existing copy in the
# user autoload directory. On Windows, the self-upgrade tail of the script is cut off.
@category shells
export def prompt [
  --config (-c): path # Prompt configuration file (defaults to `$env.POSH_CONFIG` if set)
]: nothing -> nothing {
  let cfg: oneof<nothing, path> = $config | default --empty $env.posh_config!?
  if $cfg == null {
    oh-my-posh init nu
  } else if ($cfg | path type) != file {
    error raise $"prompt configuration file not found: '($cfg)'" --kind not_found
  } else if $cfg !~ $PROMPT_EXT {
    error raise $"unexpected configuration file format: '($cfg)'" --kind invalid_argument --advice 'oh-my-posh reads toml, yaml, yml, json and jsonc files'
  } else {
    oh-my-posh init nu --config=($cfg)
  }
  let src: path = (scope true).autoload | path join oh-my-posh.nu
  if ($src | path exists) {
    let dst: path = $src | path dirname --replace=(machine-config).autoload
    if $dst != $src { mkdir ($dst | path dirname); mv --force $src $dst }
    if $nu.os-info.name == windows {
      open --raw $dst
      | collect { lines | take until { str contains '$_omp_executable upgrade' } | str join (char newline) }
      | save --force $dst
    }
  }
}

# ——— environment ——————————————————————————————————————————————————————————————

# Put the library's directories and the vendor scope on NU_LIB_DIRS, NU_PLUGIN_DIRS and PATH (idempotent: existing
# entries are kept and nothing is duplicated). A broken machine override file must not break `use conf` (the
# owner's env.nu runs it at every shell start): it is reported on stderr and the defaults are loaded instead;
# an explicit `conf machine-config` still raises the error. Any other error is not the file's fault and is raised
# as it is.
export-env {
  let libs: record = {NU_LIB_DIRS: $NU_LIB_DIRS NU_PLUGIN_DIRS: $NU_PLUGIN_DIRS}
  try {
    $libs | vars --vendor --load
  } catch {|e|
    # Only the override file's own errors (`conf::machine::*`) are worked around.
    if not ($e.details?.code? | default '' | str starts-with 'conf::machine::') { $e.raw }
    # The cause is the help: a validation hint, or a failing script's stderr (collapsed to one line).
    let cause: string = $e.details?.help? | default '' | lines | str trim | compact --empty | str join ' | ' | str substring 0..240
    let warning: string = 'conf: the machine override file was ignored, using the defaults:' | style paint yellow
    print --stderr $"($warning) ($e.msg)(if $cause != '' { $' — ($cause)' })"
    $libs | vars --vendor --load --no-file
  }
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
  | where $it not-in [conf find --path -p] and ($it | is-not-empty)
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
