# Display wrapper module for native linux and SSH remote usage.
#
# Tracking lives in this process's job table: `status` in another shell shows the
# containers but only the applications that shell launched or registered itself.

use ../log
use ../windows [ powershell "powershell x" "path as-windows" "win home" "win which" ]
use std/util null-device

# ——— constants ————————————————————————————————————————————————————————————————

const DIR: path = path self .
const XRS: path = $nu.home-dir | path join .Xresources
const PORT: int = 5901
const ENV: record<DISPLAY: string, XDG_RUNTIME_DIR: string, DBUS_SESSION_BUS_ADDRESS: string> = {
  DISPLAY: ':1'
  XDG_RUNTIME_DIR: '/run/user/'
  DBUS_SESSION_BUS_ADDRESS: 'unix:path='
}
const SEL: list<cell-path> = [$.pid $.name $.status $.mem]
const LOCAL: list<string> = [
  DISPLAY
  WAYLAND_DISPLAY
  XDG_RUNTIME_DIR
  DBUS_SESSION_BUS_ADDRESS
  WSL2_GUI_APPS_ENABLED
  WSL_DISTRO_NAME
  WSL_INTEROP
]
const OPT: list<string> = [
  -geometry
  1920x1080
  -depth
  '24'
  -nolisten
  unix
  -SecurityTypes
  VncAuth
  -PasswordFile
  ($nu.home-dir | path join .config tigervnc passwd)
  -CompareFB
  '2'
  -ZlibLevel
  '1'
]
const MAP: record<claude-desktop: list<string>> = {
  claude-desktop: [--ozone-platform=wayland]
}
const CONTAINERS: record<xvnc: string, openbox: string, tint2: string, mstsc: string> = {
  xvnc: Xtigervnc
  openbox: openbox
  tint2: tint2
  mstsc: mstsc.exe
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Ensure the display containers for the current mode, then launch an application.
#
# Without `app` only the containers are ensured. An application already tracked as a
# job is not started twice; an untracked process with the same name is killed first.
# `--mode` (or `$env.UI_SESSION_MODE`) overrides the detected session type for the call.
@category platform
@example 'ensure the containers and report status' { ui }
@example 'launch an application, passing arguments through' { ui xterm -fa Mono }
@example 'launch under WSLg and maximize the window' { ui claude-desktop --maximize }
@example 'force the session type for one launch' { ui --mode ssh xterm }
export def --wrapped main [
  app?: string@_apps # Executable name or path to launch
  --mode (-m): string@['ssh' 'xrdp' 'wslg'] # Override the session type
  --maximize (-M) # Maximize the window after spawning (WSLg only)
  ...rest: string # Arguments passed through to the application
]: nothing -> record {
  if $mode != null and $mode not-in [ssh xrdp wslg] { error make --unspanned $"unknown session mode '($mode)'" }
  let override: record = $mode
    | default { $env | get --ignore-case --optional $.ui_session_mode }
    | wrap UI_SESSION_MODE
    | compact
  with-env $override {
    let procs: table = snapshot
    let m: string = ensure (mode $procs) $procs
    if $app == null { return (status) }
    let name: string = $app | path basename
    if ($procs | tracked | where name == $name | is-not-empty) {
      log info $"detected existing '($name)' job"
      return (status)
    }
    if ($procs | pids-of $name | is-not-empty) {
      log warning $"detected orphaned '($name)' process; restarting..."
      halt --procs $procs $name
    }
    let args: list<string> = if $m == wslg {
      $MAP | get --optional $name
    } | default [] | append $rest
    spawn $name --with (session-env $m) { run-external $app ...$args }
    if $maximize and $m == wslg { maximize ($name | split words | first) }
    status
  }
}

# Report the display mode, container processes, VNC listeners, and tracked applications.
@example 'inspect the session' { ui status }
@category platform
export def status []: nothing -> record<mode: string, xvnc: oneof<nothing, record>, openbox: oneof<nothing, record>, tint2: oneof<nothing, record>, mstsc: oneof<nothing, record>, listeners: oneof<nothing, int>, apps: table> {
  let procs: table = snapshot
  let m: string = mode $procs
  {mode: $m}
  | merge ($CONTAINERS | update cells {|n| $procs | row $n })
  | merge {
    listeners: (if $m == ssh { listeners })
    apps: ($procs | tracked --exclude=($CONTAINERS | values))
  }
}

# Return the environment record that applications are launched with.
@example 'run a command under the display environment' { with-env (ui env) { xeyes } }
@category env
export def env []: nothing -> record { session-env (mode (snapshot)) }

# Track running applications by name so `status` and `stop` cover them after a shell restart.
#
# Each name resolves to a process (exact name first, then a command-line match) and a
# watcher job named after that process ends once the process disappears.
@example 'adopt an application started elsewhere' { ui register xterm }
@category platform
export def register [...names: string@_running]: nothing -> record {
  let procs: table = snapshot
  let known: list<string> = $procs | tracked | get name
  for n in $names {
    let pid: oneof<nothing, int> = $procs | pids-of --fuzzy $n | first
    let name: oneof<nothing, string> = $procs | where pid == $pid | get --optional 0.name
    if $name == null {
      log warning $"no process matched '($n)'"
    } else if $name in $known {
      log info $"'($name)' is already tracked"
    } else {
      # ponytail: the watcher polls /proc, so this is Linux-only like the rest of the module
      job spawn --description=$name { while ($'/proc/($pid)' | path exists) { sleep 1sec } }
      log info $"registered '($name)' \(pid: ($pid))"
    }
  }
  status
}

# Stop an application by name (tracked or not), or every tracked application when no name is given.
@example 'stop one application' { ui stop xterm }
@example 'stop all tracked applications' { ui stop }
@category platform
export def stop [app?: string@_tracked]: nothing -> record {
  let procs: table = snapshot
  let names: list<string> = tracked --procs=$procs --exclude=($CONTAINERS | values) | get name
  halt --procs=$procs ...(if $app == null { $names } else { [$app] })
  status
}

# Stop tracked applications and the display containers.
@example 'tear the session down' { ui terminate }
@category platform
export def terminate []: nothing -> record {
  let procs: table = snapshot
  let names: list<string> = tracked --procs=$procs | get name | append ($CONTAINERS | values) | uniq
  halt --procs=$procs ...$names
  status
}

# Terminate, then ensure the display containers again.
@example 'recover from a wedged container' { ui restart }
@category platform
export def restart []: nothing -> record { terminate | ignore; main }

# Repair the WSLg display by forcibly restarting `msrdc`.
@example 'restart the WSLg RDP client' { ui repair }
@category platform
export def repair []: nothing -> nothing {
  if (mode (snapshot)) != wslg { log warning 'detected non-WSLg display setup; results may vary' }
  powershell x 'Stop-Process -Name msrdc -Force -ErrorAction Ignore' | complete | match $in.exit_code {
    0 => { log info 'restarted msrdc' }
    $c => { log warning $"msrdc was not restarted \(exit code ($c))" }
  }
}

# Maximize a WSLg window by title through `utils.psm1`.
@example 'maximize the window titled Claude' { ui maximize Claude }
@category platform
export def maximize [name?: string@_tracked]: nothing -> nothing {
  let psm: string = $DIR | path join utils.psm1 | path as-windows
  let arg: string = match $name { null => '' _ => { $name | str replace --all "'" "''" | $"'($in)'" } }
  job spawn --description=ui-maximize { powershell x $"Import-Module '($psm)'; Set-WSLgFullscreen ($arg)" | ignore }
  sleep 1sec
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def find-jobs [
  --exclude: list<string> = []
]: oneof<nothing, list<string>> -> table<id: int, description: string, pids: list> {
  let match = $in
  job list | where $it has description and description not-in $exclude and (
    $match == null or description in $match
  )
}

# One process snapshot per command; every lookup filters this table instead of forking.
def snapshot [procs?: table]: oneof<nothing, table> -> table {
  default $procs
  | default { ps --long | where status != Zombie | uniq-by pid }
}

# Rows are tried in order and a row matches on its environment condition or on its exact-name
# container process, so an earlier row's environment beats a later row's process evidence
# (an SSH login with no DISPLAY is ssh even if mstsc.exe is up). Nothing matched means wslg.
def mode [procs: table]: nothing -> string {
  let e: record = $env | (
      select --ignore-case --optional
      $.ssh_connection
      $.xrdp_session
      $.display
      $.ui_session_mode
    ) | compact

  $e.ui_session_mode? | match $in {
    null => { }
    ssh | xrdp | wslg => { return $in }
    $x => { log warning $"ignoring unknown session mode override '($x)'" }
  }

  [
    [mode cond proc];
    [ssh ($e has ssh_connection or $e.display? in [null ':1']) Xtigervnc]
    [xrdp ($e has xrdp_session or $e.display? == ':10') mstsc.exe]
  ] | where $it.cond or ($procs | pids-of $it.proc | is-not-empty)
  | get --optional 0.mode
  | default wslg
}

def session-env [m: string]: nothing -> record {
  match $m {
    ssh => {
      $ENV
      | update XDG_RUNTIME_DIR { path join (id -u) }
      | update DBUS_SESSION_BUS_ADDRESS {|r| $in + ($r.XDG_RUNTIME_DIR | path join bus) }
    }
    xrdp => {
      $env
      | select --optional ...$LOCAL
      | compact
      | merge {DISPLAY: ':10'}
    }
    _ => {
      $env
      | select --optional ...$LOCAL
      | compact
    }
  }
}

def pids-of [
  name: string
  --fuzzy # Fall back to a case-insensitive command-line substring match when no exact name matches
  --procs: table
]: oneof<nothing, table> -> list<int> {
  let procs: table = snapshot $procs
  let n: string = $name | str lowercase
  # ponytail: `ps` truncates `name` to 15 characters, so longer executables only match with --fuzzy
  $procs
  | where ($it.name | str lowercase) == $n
  | default --empty { if $fuzzy { $procs | where ($it.command | str contains --ignore-case $name) } else { [] } }
  | get pid
}

# First exact-name row from the snapshot, projected to the shared shape.
def row [name: string --procs: table]: oneof<nothing, table> -> oneof<nothing, record> {
  let procs: table = snapshot $procs
  let pid: oneof<nothing, int> = $procs | pids-of $name | get --optional 0
  $procs
  | where pid == $pid
  | first
  | if $in != null { select ...$SEL }
}

# Jobs with a description, joined to the snapshot by their external's pid or, for registered
# watchers, by exact process name.
def tracked [
  --procs: table
  --exclude: list<string> = []
]: oneof<nothing, table> -> table {
  let procs: table = snapshot $procs
  find-jobs --exclude=$exclude | each {|j|
    let pid: oneof<nothing, int> = $j.pids.0?
      | default { $procs | pids-of $j.description | first }
    $procs | where pid == $pid | first | if $in != null {
      select ...$SEL | update name $j.description
    }
  } | compact
}

def spawn [name: string cmd: closure --with: record = {}]: nothing -> int {
  let id: int = job spawn --description=$name { with-env $with $cmd }
  log info $"spawned '($name)' \(job ($id))"
  $id
}

# Spawn whatever the mode needs and return the effective mode (wslg becomes xrdp once mstsc is up).
def ensure [m: string procs: table]: nothing -> string {
  let vars: record = session-env $m
  let down: closure = {|name: string| $procs | pids-of $name | is-empty }
  match $m {
    ssh => {
      if (do $down Xtigervnc) {
        spawn Xtigervnc --with $vars { Xtigervnc $ENV.DISPLAY -localhost ...$OPT }
        sleep 1sec
        if (listeners) == 0 {
          let g = $nu.home-dir
            | path join .config tigervnc *.log
            | into glob
          let p: oneof<nothing, path> = try { ls $g } catch { [] }
            | sort-by modified
            | get name
            | last
          if $p != null {
            open --raw $p | lines | last 20 | str join (char newline)
          } else {
            $"no tigervnc log found \(glob: '($g)')"
          } | wrap help
          | insert msg 'xtigervnc did not survive startup'
          | error make --unspanned $in
        }
        with-env $vars { xrdb -merge $XRS out+err> (null-device) }
      }
      if (do $down openbox) { spawn openbox --with $vars { openbox } }
      if (do $down tint2) { spawn tint2 --with $vars { tint2 } }
    }
    wslg => { if (do $down mstsc.exe) and (spawn-mstsc) { return 'xrdp' } }
  }
  return $m
}

def spawn-mstsc []: nothing -> bool {
  try {
    let rdp: path = $env.RDP_CONFIG_FILE?
      | default { win home --join=[wsl.rdp] }
      | let p: path
      | try { path expand --strict } catch {
        error make --unspanned $"unable to resolve RDP config file: '($p)'"
      }
    let exe: path = win which mstsc.exe | default {
        error make --unspanned "unable to locate 'mstsc.exe' executable"
      }
    let cfg: string = $rdp | path as-windows
    spawn mstsc.exe { run-external $exe $cfg out+err> (null-device) }
    sleep 1sec
    return true
  } catch {|e|
    log warning $e.msg
    return false
  }
}

# SIGTERM every pid behind the names (job pids, exact-name orphans, registered apps), settle,
# then `job kill` whatever job is still listed (that one is SIGKILL).
def halt [...names: string --procs: table]: nothing -> nothing {
  let procs: table = snapshot $procs
  let jobs: table = $names | find-jobs
  let pids: list<int> = [
    ...$jobs.pids
    ...($names | each {|n| $procs | pids-of $n })
  ] | flatten --all | uniq

  if ($jobs | is-empty) and ($pids | is-empty) { return }

  for pid in $pids { kill --quiet $pid }
  sleep 1sec
  for j in ($names | find-jobs) { job kill $j.id }

  let hit: list<string> = [
    ...$jobs.description
    ...($procs | where pid in $pids).name
  ] | uniq
  log info $"stopped ($hit | str join ', ')"
}

def listeners []: nothing -> int {
  ss -ltn | complete | get stdout | lines | where $it =~ $':($PORT)\s' | length
}

# ——— completions ——————————————————————————————————————————————————————————————

# Tracked application names plus executables on PATH, for launching.
def _apps []: nothing -> list<string> {
  _tracked | append (which | where type == external | get command | path basename) | uniq
}

# Tracked application names, for stopping or maximizing.
def _tracked []: nothing -> list<string> {
  job list | get --optional description | compact | where $it not-in ($CONTAINERS | values) | uniq
}

# Untracked running processes, limited to those started after the earliest live container.
def _running []: nothing -> table<value: string, description: string> {
  let procs: table = snapshot
  let names: list<string> = $CONTAINERS | values | str lowercase
  let since: oneof<nothing, datetime> = $procs
    | where ($it.name | str lowercase) in $names
    | get start_time | sort | get --optional 0
  let known: list<string> = _tracked
  $procs
  | if $since == null { } else { where start_time > $since }
  | where ($it.name | str lowercase) not-in $names and name not-in $known
  | sort-by start_time --reverse
  | uniq-by name
  | insert description {|row| $"pid: ($row.pid); started ($row.start_time | date humanize)" }
  | select $.name $.description
  | rename --column={name: value}
}
