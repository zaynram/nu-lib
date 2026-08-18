# Displau wrapper module for native linux and SSH remote usage.

use ../../_internal/log
use std null-device

# ——— constants ————————————————————————————————————————————————————————————————

const DIR: path = path self .
const XRS: path = $nu.home-dir | path join .Xresources
const DIM: string = '1920x1080'
const ENV: record = {
  DISPLAY: ':1'
  XDG_RUNTIME_DIR: '/run/user/'
  DBUS_SESSION_BUS_ADDRESS: 'unix:path='
  LISTENER_PORT: 5901
}
const COL: list<string> = [
  DISPLAY
  WAYLAND_DISPLAY
  XDG_RUNTIME_DIR
  DBUS_SESSION_BUS_ADDRESS
]
const MAP: record = {
  claude-desktop: [--ozone-platform=wayland]
}
const OPT: record = {
  -geometry: $DIM
  -depth: 24
  -nolisten: unix
  -SecurityTypes: VncAuth
  -PasswordFile: ($nu.home-dir | path join .config tigervnc passwd)
  -CompareFB: 2
  -ZlibLevel: 1
}
const EXC: list = [tint2 Xtigervnc openbox]
const WPS: list<string> = [/mnt/c/Windows/System32/WindowsPowerShell/v1.0/]

# ——— helpers ——————————————————————————————————————————————————————————————————

export alias repair = job spawn --description=disp-repair {
  with-env {PATH: ($env.PATH ++ $WPS)} {
    powershell.exe -ExecutionPolicy Bypass -Command "Stop-Process -Name msrdc -Force -ErrorAction SilentlyContinue" out+err> (null-device)
  }
}

alias check-listeners = try { ss -ltn | find $ENV.LISTENER_PORT } catch { [] }
alias repr-job = match ($in | compact --empty) {
  {id: $n description: $d} => $"job '($d)' \(id: ($n))"
  {id: $n} => $'job ($n)'
}

def is-remote []: nothing -> bool { $env has SSH_CONNECTION }

def --env update-applications [
  ...names: string
]: oneof<nothing, list<string>> -> nothing {
  let curr: list = $env.disp.apps? | default [] | get --optional name | compact
  let apps: table = $in
    | append [...$names ...$curr]
    | uniq
    | compact
    | path basename
    | reduce --fold=[] {|app acc|
      $acc
      | append (proc $app)
      | compact
      | uniq-by pid
    } | select name pid status mem
  $env.disp.apps = $apps
}

def --env update-vncserver [
  only?: string@[xtigervnc openbox]
]: nothing -> nothing {
  $env.disp = $env.disp
    | match $only {
      xtigervnc => { upsert xvnc { proc Xtigervnc --unwrap } }
      openbox => { upsert openbox { proc openbox --unwrap } }
      _ => {
        merge {
          xvnc: (proc Xtigervnc --unwrap)
          openbox: (proc openbox --unwrap)
        }
      }
    }
}

def --env update-listeners []: nothing -> nothing {
  $env.disp.listeners = check-listeners | length
}
export-env {
  if $env.ENV_CONVERSIONS not-has display {
    repair
    $env.ENV_CONVERSIONS.disp = {
      from_string: {|s|
        default $s
        | split row (char esep)
        | where $it =~ '\d+'
        | into int
        | reduce --fold {
          apps: []
          xvnc: (proc Xtigervnc --unwrap)
          openbox: (proc openbox --unwrap)
          listeners: (check-listeners | length)
        } {|id acc|
          $acc | upsert apps {
            append (proc --unwrap $id)
            | compact
            | uniq-by pid
            | select name pid status mem
          }
        }
      }
      to_string: {|v|
        $v.apps?.pid?
        | default []
        | into string
        | str join (char esep)
      }
    }
  }
  $env.disp = $env.disp?
    | match ($in | describe) {
      nothing => {
        apps: []
        xvnc: (proc Xtigervnc --unwrap)
        openbox: (proc openbox --unwrap)
        listeners: (check-listeners | length)
      }
      string => { do $env.ENV_CONVERSIONS.display.from_string $in }
      _ => $in
    }
}

def kill-one [--strict]: oneof<string, record<name: string>> -> nothing {
  let name: string = match ($in | describe) { string => $in _ => $in.name }
  job --kill $name
  let args: list = [--ignore-case (if $strict { '--exact' } else { '--full' }) $name]
  pkill ...$args out+err> (null-device)
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Consume the display session environment.
export def env [
  --exec (-x): closure # Closure to run under this environment
  --async (-a): string # Label for a job to wrap the `--exec` closure with
]: oneof<nothing, record> -> oneof<int, string, nothing> {
  let base: record = $in | default {}
  let full: record = if (is-remote) {
    $ENV
    | update XDG_RUNTIME_DIR { path join (id -u) }
    | update DBUS_SESSION_BUS_ADDRESS {|_| $in + $_.XDG_RUNTIME_DIR }
  } else {
    $env | select ...$COL
  } | merge $base
  match ($exec | describe) {
    nothing => { return $full }
    closure if $async == null => { with-env $full $exec }
    closure => { job spawn --description=$async { with-env $full $exec } }
  }
}

# Collect processes matching a query string.
#
# Any detected zombie processes will automatically be terminated.
export def proc [
  arg: oneof<int, string> # PID or string to filter names with (regex matched)
  --unwrap (-u) # Only operate on the first matching process entry
]: nothing -> oneof<nothing, table, record, list<int>> {
  let ps: table = if $arg not-in $EXC { ps --long } else { ps }
  let ps: table = match ($arg | describe) {
    int => { $ps | where pid == $arg }
    string if ($ps | any { $in not-has command }) => { $ps | where name =~ $arg }
    string => { $ps | where name =~ $arg and command ends-with $arg }
  }
  try {
    $ps | where status != Zombie | if $unwrap { first } else { }
  } catch {
    return []
  } finally {
    job spawn --description=__prune-zombies {
      let old: table = $ps
        | group-by status
        | get --optional Zombie
        | default []
      if ($old | is-not-empty) { kill --force ...$old.pid }
    }
  }
}

# Manage the process jobs.
export def job [
  arg: oneof<int, string> # ID or description to filter job entries by
  --kill (-k) # Kill the job(s) with matching descriptions
  --unwrap (-u) # Only operate on the first matching job entry
  --pids (-p) # Return a list of process IDs from the matching jobs
]: nothing -> oneof<nothing, table, record, list<int>> {
  job list | match ($arg | describe) {
    int => { where id == $arg }
    string => { where description == $arg }
  } | match $in {
    [] => { return }
    _ if $unwrap => { first }
    _ => { }
  } | if $kill {
    let queue: table = $in
    for job in $queue {
      try {
        job kill $job.id
        log info $"killed ($job | repr-job)"
      } catch {
        log error $"unable to kill ($job | repr-job)"
      }
    }
  } else if $pids {
    get --optional pids | compact --empty | flatten
  } else { }
}

# Return a table of detected running applications.
export def apps [
  --for-each: closure # Closure to run with each of the applications
  --no-update # Disable auto-refresh of the application list after `--for-each` completes
]: nothing -> oneof<nothing, table> {
  update-applications
  $env.disp.apps
  | where $it not-in $EXC
  | if $for_each == null { } else {
    let apps: table = $in
    for a in $apps { $a | do --ignore-errors $for_each $a }
    if not $no_update { update-applications }
  }
}

# Move windows with powershell.
export def maximize [name?: string]: nothing -> nothing {
  let p: path = $DIR | path join utils.psm1
  job spawn --description=disp-maximize {
    with-env {PATH: ($env.PATH ++ $WPS)} {
      powershell.exe -ExecutionPolicy Bypass -Command $"Import-Module ($p); Set-WSLgFullscreen ($name)" out+err> (null-device)
    }
  } | ignore
}

# Launch a graphical application, with automatic display process spawn handling.
#
# When run with an `app` on the server directly, the application will be launched directly.
export def --env --wrapped main [
  app?: oneof<path, string>@_apps
  # The name or path of an application to start
  --default (-d)
  # Spawn the default terminal emulator (cannot be combined with an `app`)
  --environ (-e)
  # Show the session environment record and return
  --kill (-k)
  # End the named application process and return the status output
  --terminate (-t)
  # Terminate the display server process and all applications
  --status (-s)
  # Show the status of the relevant display and application processes
  --options (-o): record = $OPT
  # Kill the existing processes and respawn them
  --force (-f)
  # Forcibly restart any processes already running
  ...rest: string
  # Argments to pass through to the application
]: nothing -> oneof<nothing, record, table> {
  if $environ { return (env) }

  if $force or $terminate {
    apps --no-update --for-each={|a| job --kill $a.name; $a | kill-one --strict }
    for x in $EXC { job --kill $x; $x | kill-one }
  } else if $kill and $app != null {
    job --kill $app
    $app | kill-one --strict
  }

  if $terminate or $kill or $status {
    update-applications
    if (is-remote) {
      update-vncserver
      update-listeners
      return $env.disp
    } else {
      return $env.disp.apps
    }
  }

  let jobs: list<string> = job list
    | where $it has description and ($it.pids? | is-not-empty)
    | get description

  if (is-remote) {
    def is-not-running [name: string]: nothing -> bool {
      $force or $jobs not-has $name and (proc $name | is-empty)
    }

    if (is-not-running Xtigervnc) {
      log info 'starting xtigervnc...'
      let args: list = $OPT
        | merge $options
        | items {|k v| [$k $v] | into string }
        | flatten
      log debug $'args: ($args | to nuon --serialize)'
      env --exec={ Xtigervnc $ENV.DISPLAY -localhost ...$args } --async=xtigervnc
      sleep 2sec
      if (check-listeners | is-empty) {
        try { ls ($nu.home-dir | path join .config tigervnc *.log | into glob) | sort-by modified | last }
        | match $in { {name: $p} => { open --raw $p | lines | last 20 | str join (char newline) } }
        | error make --unspanned {
          msg: 'xtigervnc did not survive startup'
          help: $in
        }
      } else {
        log info 'xtigervnc started succesfully'
        update-vncserver xtigervnc
      }
    }

    if (is-not-running openbox) {
      log info 'starting openbox...'
      env --exec={ openbox } --async=openbox
      | log info $"spawned openbox process job \(id: ($in))"
      sleep 1sec
      update-vncserver openbox
    }

    env --exec={ xrdb -merge $XRS out+err> (null-device) }

    if (is-not-running tint2) {
      log info 'starting tint2...'
      env --exec={ tint2 } --async=tint2
      | log info $"spawned tint2 process job \(id: ($in))"
      sleep 1sec
      update-applications tint2
    }
  }

  let name: oneof<nothing, string> = match $app {
    null if not $default => { return $env.disp }
    null => 'x-terminal-emulator'
    _ => { $app | path basename }
  }

  if $force or $jobs not-has $name {
    if (proc $name | is-not-empty) {
      log warning $'detected orphaned app process; restarting ($name)...'
      pkill -f $name out+err> (null-device)
      sleep 1sec
      log info $'killed orphaned ($name) process'
    }

    log info $'starting application ($name)...'
    if (is-remote) {
      env --exec={ run-external $app ...$rest } --async=$app
      sleep 1sec
    } else {
      let args: list<string> = $MAP | get --optional $app | append $rest | compact | uniq
      let id: int = env --exec={ run-external $app ...$args } --async=$app
      sleep 2sec
      maximize ($app | split words | first); $id
    } | log info $"spawned ($name) process job \(id: ($in))"
    update-applications $app
  }

  $env.disp | if (is-remote) { compact --empty } else { get apps }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _apps []: nothing -> list {
  scope commands | where type == external | append $env.disp.apps | get name | uniq
}
