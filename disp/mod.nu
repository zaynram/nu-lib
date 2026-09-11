# Display wrapper module for native linux and SSH remote usage.

use ../log
use ../windows [powershell "powershell x" "path as-windows" "win home" "win which"]
use std null-device

# ——— constants ————————————————————————————————————————————————————————————————

const DIR: path = path self .
const XRS: path = $nu.home-dir | path join .Xresources
const PORT: int = 5901
const ENV: record<DISPLAY: string, XDG_RUNTIME_DIR: string, DBUS_SESSION_BUS_ADDRESS: string> = {
  DISPLAY: ':1'
  XDG_RUNTIME_DIR: '/run/user/'
  DBUS_SESSION_BUS_ADDRESS: 'unix:path='
}
const COL: list<string> = [
  DISPLAY
  WAYLAND_DISPLAY
  XDG_RUNTIME_DIR
  DBUS_SESSION_BUS_ADDRESS
  WSL2_GUI_APPS_ENABLED
  WSL_DISTRO_NAME
  WSL_INTEROP
]
const OPT: list<string> = [
  -geometry 1920x1080
  -depth '24'
  -nolisten unix
  -SecurityTypes VncAuth
  -PasswordFile ($nu.home-dir | path join .config tigervnc passwd)
  -CompareFB '2'
  -ZlibLevel '1'
]
const MAP: record<claude-desktop: list<string>> = {claude-desktop: [--ozone-platform=wayland]}
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
@category platform
@example 'ensure the containers and report status' { disp }
@example 'launch an application, passing arguments through' { disp xterm -fa Mono }
@example 'launch under WSLg and maximize the window' { disp claude-desktop --maximize }
export def --wrapped main [
  app?: string@_apps # Executable name or path to launch
  --maximize (-m) # Maximize the window after spawning (WSLg only)
  ...rest: string # Arguments passed through to the application
]: nothing -> record {
  let procs: table = snapshot
  let m: string = mode $procs
  ensure $m $procs
  if $app == null { return (status) }
  let name: string = $app | path basename
  if (tracked --procs $procs | where name == $name | is-not-empty) {
    log info $"detected existing '($name)' job"
    return (status)
  }
  if (pids-of --procs $procs $name | is-not-empty) {
    log warning $"detected orphaned '($name)' process; restarting..."
    halt --procs $procs $name
  }
  let args: list<string> = if $m == wslg { $MAP | get --optional $name | default [] } else { [] } | append $rest
  spawn $name --with (session-env $m) { run-external $app ...$args }
  if $maximize and $m == wslg { maximize ($name | split words | first) }
  status
}

# Report the display mode, container processes, VNC listeners, and tracked applications.
@example 'inspect the session' { disp status }
@example 'relaunch tracked applications' { disp status | get apps.name | each { disp $in } }
export def status []: nothing -> record<mode: string, xvnc: oneof<nothing, record>, openbox: oneof<nothing, record>, tint2: oneof<nothing, record>, mstsc: oneof<nothing, record>, listeners: oneof<nothing, int>, apps: table> {
  let procs: table = snapshot
  let m: string = mode $procs
  {mode: $m}
  | merge ($CONTAINERS | update cells {|n| row --procs $procs $n })
  | merge {
    listeners: (if $m == ssh { listeners })
    apps: (tracked --procs $procs | where name not-in ($CONTAINERS | values))
  }
}

# Return the environment record that applications are launched with.
@example 'run a command under the display environment' { with-env (disp env) { xeyes } }
export def env []: nothing -> record { session-env (mode (snapshot)) }

# Track running applications by name so `status` and `stop` cover them after a shell restart.
#
# Each name resolves to a process (exact name first, then a command-line match) and a
# watcher job named after that process ends once the process disappears.
@example 'adopt an application started elsewhere' { disp register xterm }
export def register [...names: string@_running]: nothing -> record {
  let procs: table = snapshot
  let known: list<string> = tracked --procs $procs | get name
  for n in $names {
    let pid: oneof<nothing, int> = pids-of --fuzzy --procs $procs $n | get --optional 0
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

# Stop a tracked application, or every tracked application when no name is given.
@example 'stop one application' { disp stop xterm }
@example 'stop all tracked applications' { disp stop }
export def stop [app?: string@_tracked]: nothing -> record {
  let procs: table = snapshot
  tracked --procs $procs
  | where name not-in ($CONTAINERS | values)
  | get name
  | if $app == null { } else { [$app] }
  | halt --procs $procs ...$in
  status
}

# Stop tracked applications and the display containers.
@example 'tear the session down' { disp terminate }
export def terminate []: nothing -> record {
  let procs: table = snapshot
  tracked --procs $procs | get name | append ($CONTAINERS | values) | uniq | halt --procs $procs ...$in
  status
}

# Terminate, then ensure the display containers again.
@example 'recover from a wedged container' { disp restart }
export def restart []: nothing -> record { terminate | ignore; main }

# Repair the WSLg display by forcibly restarting `msrdc`.
@example 'restart the WSLg RDP client' { disp repair }
export def repair []: nothing -> nothing {
  if (mode (snapshot)) != wslg { log warning 'detected non-WSLg display setup; results may vary' }
  powershell x 'Stop-Process -Name msrdc -Force -ErrorAction Ignore' | complete | match $in.exit_code {
    0 => { log info 'restarted msrdc' }
    $c => { log warning $"msrdc was not restarted \(exit code ($c))" }
  }
}

# Maximize a WSLg window by title through `utils.psm1`.
@example 'maximize the window titled Claude' { disp maximize Claude }
export def maximize [name?: string@_tracked]: nothing -> nothing {
  let psm: path = $DIR | path join utils.psm1
  job spawn --description=disp-maximize { powershell x $"Import-Module ($psm); Set-WSLgFullscreen ($name)" | ignore }
  sleep 1sec
}

# ——— helpers ——————————————————————————————————————————————————————————————————

# One process snapshot per command; every lookup filters this table instead of forking.
def snapshot [procs?: table]: nothing -> table {
  $procs | default { ps --long | where status != Zombie | uniq-by pid }
}

# Exact-name evidence from the snapshot first (a command-line match can never flip the mode), then the environment.
def mode [procs: table]: nothing -> string {
  if (pids-of --procs $procs Xtigervnc | is-not-empty) { return 'ssh' }
  if (pids-of --procs $procs mstsc.exe | is-not-empty) { return 'xrdp' }
  match ($env | select --optional SSH_CONNECTION DISPLAY XRDP_SESSION | compact) {
    {SSH_CONNECTION: _ DISPLAY: ':1'} => 'ssh'
    {XRDP_SESSION: _ DISPLAY: ':10'} => 'xrdp'
    _ => 'wslg'
  }
}

def session-env [m: string]: nothing -> record {
  match $m {
    ssh => {
      $ENV
      | update XDG_RUNTIME_DIR { path join (id -u) }
      | update DBUS_SESSION_BUS_ADDRESS {|r| $in + ($r.XDG_RUNTIME_DIR | path join bus) }
    }
    xrdp => { $env | select --optional ...$COL | compact | merge {DISPLAY: ':10'} }
    _ => { $env | select --optional ...$COL | compact }
  }
}

def pids-of [
  name: string
  --fuzzy # Fall back to a case-insensitive command-line match when no exact name matches
  --procs: table
]: nothing -> list<int> {
  let procs: table = snapshot $procs
  let n: string = $name | str lowercase
  $procs
  | where ($it.name | str lowercase) == $n
  | default --empty { if $fuzzy { $procs | where command =~ ('(?i)' + $name) } else { [] } }
  | get pid
}

# First exact-name row from the snapshot, projected to the shared shape.
def row [name: string --procs: table]: nothing -> oneof<nothing, record> {
  let procs: table = snapshot $procs
  let pid: oneof<nothing, int> = pids-of --procs $procs $name | get --optional 0
  $procs | where pid == $pid | get --optional 0 | if $in != null { select pid name status mem }
}

# Jobs with a description, joined to the snapshot by their external's pid or, for registered
# watchers, by exact process name.
def tracked [--procs: table]: nothing -> table {
  let procs: table = snapshot $procs
  job list
  | where {|j| $j.description? | is-not-empty }
  | each {|j|
    let pid: oneof<nothing, int> = $j.pids.0? | default { pids-of --procs $procs $j.description | get --optional 0 }
    $procs | where pid == $pid | get --optional 0 | if $in != null { select pid name status mem | update name $j.description }
  }
  | compact
}

def spawn [name: string cmd: closure --with: record = {}]: nothing -> int {
  let id: int = job spawn --description=$name { with-env $with $cmd }
  log info $"spawned '($name)' \(job ($id))"
  $id
}

def ensure [m: string procs: table]: nothing -> nothing {
  let vars: record = session-env $m
  let down: closure = {|name: string| pids-of --procs $procs $name | is-empty }
  match $m {
    ssh => {
      if (do $down Xtigervnc) {
        spawn Xtigervnc --with $vars { Xtigervnc $ENV.DISPLAY -localhost ...$OPT }
        sleep 1sec
        if (listeners) == 0 {
          error make --unspanned {
            msg: 'xtigervnc did not survive startup'
            help: (
              try {
                ls ($nu.home-dir | path join .config tigervnc *.log | into glob)
                | sort-by modified | last | get name | open --raw | lines | last 20 | str join (char newline)
              } catch { 'no tigervnc log found' }
            )
          }
        }
        with-env $vars { xrdb -merge $XRS out+err> (null-device) }
      }
      if (do $down openbox) { spawn openbox --with $vars { openbox } }
      if (do $down tint2) { spawn tint2 --with $vars { tint2 } }
    }
    wslg => {
      if (do $down mstsc.exe) { try { spawn-mstsc } catch {|e| log warning $e.msg } }
    }
  }
}

def spawn-mstsc []: nothing -> nothing {
  let rdp: path = $env.RDP_CONFIG_FILE? | default { win home --join=[wsl.rdp] } | path expand
  if not ($rdp | path exists) { error make --unspanned $"unable to resolve RDP configuration file: '($rdp)'" }
  let exe: path = win which mstsc.exe | default { error make --unspanned "unable to locate 'mstsc.exe' executable" }
  let cfg: string = $rdp | path as-windows
  spawn mstsc.exe { run-external $exe $cfg out+err> (null-device) }
  sleep 1sec
}

# Kill tracked jobs by description, then any remaining exact-name processes (orphans and registered apps).
def halt [...names: string --procs: table]: nothing -> nothing {
  let procs: table = snapshot $procs
  let jobs: table = job list | where {|j| $j.description? in $names }
  let pids: list<int> = $names | each {|n| pids-of --procs $procs $n } | flatten
  if ($jobs | is-empty) and ($pids | is-empty) { return }
  for j in $jobs { job kill $j.id }
  for pid in $pids { kill --quiet $pid }
  sleep 1sec
  let hit: list<string> = $jobs | get description | append ($procs | where pid in $pids | get name) | uniq
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
  $procs
  | if $since == null { } else { where start_time > $since }
  | where ($it.name | str lowercase) not-in $names and name not-in (_tracked)
  | sort-by start_time --reverse
  | uniq-by name
  | each { {value: $in.name description: $"pid ($in.pid), ($in.start_time | date humanize)"} }
}
