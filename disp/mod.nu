# Display wrapper module for native linux and SSH remote usage.

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
  WSL2_GUI_APPS_ENABLED
  WSL_DISTRO_NAME
  WSL_INTEROP
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
const EXC: list = [tint2 Xtigervnc openbox mstsc.exe]
const PSE: path = '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
const VAR: list<string> = [WSL_INTEROP DISPLAY SSH_CONNECTION XRDP_SESSION]

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  try {
    if ($env.ENV_CONVERSIONS? | default {}) not-has disp {
      # Serializer takes string argument for cases where deserialization fails.
      let serialize = {|v: oneof<nothing, string, record<apps: list>>|
        $v | match ($in | describe | split words | first) {
          string if ($v | is-not-empty) => { return $v }
          string | nothing => []
          record => { get --optional $.apps.pid | default [] | compact }
          _ => []
        } | into string | str join (char esep)
      }
      # Deserializer takes optional argument for cases of manual invocation.
      let deserialize = {|s?: string|
        if $s == null {
          $env.disp | match ($in | describe | split words | first) {
            string => { split row (char esep) }
            record if ($in.apps? | describe) == string => { get $.apps | split row (char esep) }
            record if ($in.apps? | is-not-empty) => { get $.apps.pid? | default [] }
            _ => []
          } | compact
        } else {
          try { $s | split row (char esep) | into int } catch { [] }
        } | par-each {|pid| proc --unwrap $pid }
        | {apps: $in listeners: (check-listeners | length | if $in > 0 { })}
        | update-containers --return
      }
      $env.ENV_CONVERSIONS = $env.ENV_CONVERSIONS
        | insert $.disp {from_string: $deserialize to_string: $serialize}
    }
  } catch {|err|
    log error $"`disp` module environment initialization did not succeed\n[error]($err.rendered?)"
  } finally {
    update-containers
    update-applications
    update-listeners
  }
}

# ——— definitions ——————————————————————————————————————————————————————————————

# Repair the WSLg display by forcibly restarting `msrdc`.
export def repair []: nothing -> string {
  if (session-type) != wslg { log warning "detected non-WSLg display setup; results may vary" }
  pwsh Stop-Process -Name msrdc -Force -ErrorAction SilentlyContinue
}

# Consume the display session environment.
export def env [
  --exec (-x): closure # Closure to run under this environment
  --async (-a): string # Label for a job to wrap the `--exec` closure with
  --wait (-w): duration = 1sec # Wait this duration before returning; only works with `--async`
  --notify (-n) = true # Log a spawn message to stdout; only works with `--async`
]: oneof<nothing, record> -> oneof<int, string, record, nothing> {
  let base: record = default {}
  let full: record = if (is-remote) {
    $ENV
    | update XDG_RUNTIME_DIR { path join (id -u) }
    | update DBUS_SESSION_BUS_ADDRESS {|_| $in + $_.XDG_RUNTIME_DIR | path join bus }
  } else {
    $env | select --optional ...$COL | compact
  } | merge $base
  match ($exec | describe) {
    nothing => { return $full }
    closure if $async == null => { with-env $full $exec }
    closure => {
      let id: int = job spawn --description=$async { with-env $full $exec }
      sleep $wait
      if $notify { notify-spawned $async $id }
      return $id
    }
  }
}

# Collect processes matching a query string.
#
# Any detected zombie processes will automatically be terminated.
export def proc [
  arg?: oneof<int, string> # PID or string to filter names with (regex matched)
  --unwrap (-u) # Only operate on the first matching process entry
]: nothing -> oneof<nothing, table, record, list<int>> {
  let procs: table<name: string, pid: int> = ps | where status != Zombie | uniq-by pid
  match ($arg | describe) {
    int => { $procs | where pid == $arg }
    string => {
      # Hoisted out of `where`: a subexpression in a row condition is re-evaluated per row.
      let pid: oneof<nothing, int> = if $EXC has $arg { pid-of $arg } else { pid-of --options=[--full --ignore-case] $arg }
      $procs | where pid == $pid
    }
    nothing => {
      $env.disp
      | reject --optional $.listeners
      | upsert $.apps { default [] | get --optional $.pid | compact }
      | compact --empty
      | transpose key value
      | reduce --fold=[] {|it acc|
        try {
          match $it.key {
            apps => { append ($procs | where pid in $it.value) }
            mstsc => { let p = pid-of mstsc.exe; append ($procs | where pid == $p) }
            xvnc => { let p = pid-of Xtigervnc; append ($procs | where pid == $p) }
            openbox => { let p = pid-of openbox; append ($procs | where pid == $p) }
          }
        } catch {|err|
          log error $"unexpected error during `$env.disp.($it.key)` process collection\n[error]($err.rendered?)"
          return $acc
        }
      }
    }
  } | default []
  | collect
  | if $unwrap { first } else { }
}

# Manage the process jobs.
export def job [
  arg?: oneof<int, string> # ID or description to filter job entries by
  --kill (-k) # Kill the job(s) with matching descriptions
  --unwrap (-u) # Only operate on the first matching job entry
  --pids (-p) # Return a list of process IDs from the matching jobs
]: nothing -> oneof<nothing, table, record, list<int>> {
  let jobs: table<id: int, pids: list<int>, description: string> = job list | default '' description | default [] pids
  match ($arg | describe) {
    int => { $jobs | where id == $arg }
    string => {
      let pid: oneof<nothing, int> = if $EXC has $arg { pid-of $arg } else { pid-of --options=[--full --ignore-case] $arg }
      $jobs | where pids has $pid
    }
    nothing => {
      $env.disp
      | reject --optional $.listeners
      | update $.apps { get --optional $.name | compact }
      | compact --empty
      | transpose key value
      | reduce --fold=[] {|it acc|
        try {
          match $it.key {
            apps => { append ($jobs | where description in $it.value) }
            mstsc => { append ($jobs | where description == mstsc) }
            xvnc => { append ($jobs | where description == xtigervnc) }
            openbox => { append ($jobs | where description == openbox) }
          }
        } catch {|err|
          log error $"unexpected error during `$env.disp.($it.key)` process collection\n[error]($err.rendered?)"
          return $acc
        }
      }
    }
  } | default []
  | collect
  | if $unwrap { first } else { }
  | if $pids and ($in | is-not-empty) { get --optional $.pids | compact --empty | flatten } else { }
}

# Return a record containing details about the host display setup.
export def host [
  --all (-a)
  # Return information about all possible host setups
  --mstsc (-m)
  # Include information about `mstsc.exe` processes
  --xtigervnc (-x)
  # Include information about `xtigervnc` processes and any listeners
  --openbox (-o)
  # Include information about `openbox` processes
]: nothing -> record {
  let type: string = session-type
  update-containers
  $env.disp | reject apps | insert mode $type | if $all {
    return $in
  } else {
    select --ignore-case --optional ...(
      [
        [cond cells];
        [($mstsc or $type == xrdp) [$.mstsc $.openbox]]
        [($xtigervnc or $type == ssh) [$.xvnc $.openbox $.listeners]]
        [($openbox or $type != wslg) [$.openbox]]
      ] | where $it.cond | get $.cells | flatten --all | uniq
    )
  }
}

# Return a table of detected running applications.
export def --env apps [
  --register: string # Name of an application to track if process is detected
  --for-each: closure # Closure to run with each of the applications
  --no-update # Disable auto-refresh of the application list after `--for-each` completes
]: nothing -> oneof<nothing, table> {
  update-applications ...(append $register | compact)
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
    pwsh Import-Module $p "\n" Set-WSLgFullscreen $name
  }
  sleep 1sec
}

# Launch a graphical application, with automatic display process spawn handling.
#
# When run with an `app` on the server directly, the application will be launched directly.
export def --env --wrapped main [
  app?: oneof<path, string>@_apps
  # The name or path of an application to start
  --refresh (-r)
  # Refresh all environment variables and return the status
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
  --maximize (-m)
  # Automatically maximize the window after spawning an app
  ...rest: string
  # Argments to pass through to the application
]: nothing -> oneof<nothing, record, table> {
  if $environ { return (env) }

  let stype: string = session-type
  let rconn: bool = $stype == ssh
  let details: closure = {||
    update-containers
    update-applications
    if $rconn { update-listeners }
    $env.disp | insert mode $stype
  }

  if $force or $terminate {
    let end_process: closure = {|x: string strict: bool = false|
      pid-of --unwrap=false $x | match ($in | describe) {
        list<any> | nothing => { job --kill $x }
        list<int> => { par-each { kill-one --signal=SIGKILL --errors=false --strict=$strict } }
      }
    }
    apps --for-each={|a| do $end_process $a.name true }
    for x in $EXC { do $end_process $x }
  } else if $kill and $app != null {
    job --kill $app
    $app | kill-one --strict --errors=false
  }

  let jobs: list<string> = job list
    | where $it has description and ($it.pids? | is-not-empty)
    | get description

  if $refresh or $terminate or $kill or $status { do $details | return $in }

  if $rconn {
    def is-not-running [name: string]: nothing -> bool {
      $force or $jobs not-has $name and not (is-running $name)
    }

    if (is-not-running Xtigervnc) {
      log info 'starting xtigervnc...'
      let args: list = $OPT
        | merge $options
        | items {|k v| [$k $v] | into string }
        | flatten
      log debug $'args: ($args | to nuon --serialize)'
      let id: int = env --exec={ Xtigervnc $ENV.DISPLAY -localhost ...$args } --async=xtigervnc --notify=false
      sleep 1sec
      if (check-listeners | is-empty) {
        try { ls ($nu.home-dir | path join .config tigervnc *.log | into glob) | sort-by modified | last }
        | match $in { {name: $p} => { open --raw $p | lines | last 20 | str join (char newline) } }
        | error make --unspanned {
          msg: 'xtigervnc did not survive startup'
          help: $in
        }
      } else {
        notify-spawned xtigervnc $id
      }
    } else {
      notify-running xtigervnc
    }

    if (is-not-running openbox) {
      log info 'starting openbox...'
      env --exec={ openbox } --async=openbox
    } else {
      notify-running openbox
    }

    env --exec={ xrdb -merge $XRS out+err> (null-device) }

    if (is-not-running tint2) {
      log info 'starting tint2...'
      env --exec={ tint2 } --async=tint2
      apps --register tint2
    } else {
      notify-running tint2
    }
  } else if $stype != xrdp {
    try { spawn-mstsc } catch {
      match ($in | compact --empty) { {msg: $m} => { log warning $m } }
      match $app { null => { do $details | return $in } }
    }
  }

  let name: oneof<nothing, string> = match $app {
    null if not $default => { return (do $details) }
    null => 'x-terminal-emulator'
    _ => { $app | path basename }
  }

  if $force or $jobs not-has $name {
    if (is-running $name) {
      log warning $'detected orphaned app process; restarting ($name)...'
      $name | kill-one
    }
    log info $'starting application ($name)...'
    if $rconn {
      env --exec={ run-external $app ...$rest } --async=$app
    } else {
      {env: {} args: []}
      | if (is-running mstsc.exe) {
        upsert $.env.DISPLAY ':10'
      } else {
        update $.args { $MAP | get --optional $app | default [] }
      } | collect {|it|
        $it.env | env --async=$app --exec={ run-external $app ...$it.args ...$rest }
        if $maximize { maximize ($app | split words | first) }
      }
    }
    apps --register $app
  }
  do $details
}

# ——— helpers ——————————————————————————————————————————————————————————————————

def rdp-config []: nothing -> path {
  $env | get --ignore-case --optional $.RDP_CONFIG_FILE | default --empty {
    $env.USERPROFILE? | default $"/mnt/c/Users/($env.USER)" | path join wsl.rdp
  }
}

def notify-running [name: string]: nothing -> nothing {
  log info $"detected existing '($name)' process \(pid: (pid-of $name))"
}

def notify-spawned [name: string id: int]: nothing -> nothing {
  log info $"spawned '($name)' process job \(id: ($id))"
}

def --wrapped pwsh [...rest: string]: nothing -> string {
  ^$PSE -ExecutionPolicy Bypass -Command ($rest | str join (char space)) err> (null-device)
}

def check-listeners []: nothing -> list {
  ss -ltn | complete | match $in.exit_code {
    0 => { get stdout | find $ENV.LISTENER_PORT }
    _ => []
  }
}

def repr-job []: record<id: int> -> string {
  match ($in | compact --empty) {
    {id: $n description: $d} => $"job '($d)' \(id: ($n))"
    {id: $n} => $'job ($n)'
  }
}

def session-type []: nothing -> string {
  match ($env | select --optional ...$VAR | compact) {
    _ if (is-running Xtigervnc) => 'ssh'
    _ if (is-running mstsc.exe) => 'xrdp'
    {SSH_CONNECTION: _ DISPLAY: ':1'} => 'ssh'
    {XRDP_SESSION: _ DISPLAY: ':10'} => 'xrdp'
    {WSL_INTEROP: _ DISPLAY: ':0'} => 'wslg'
  } | default 'wslg'
}

def is-remote []: nothing -> bool { (session-type) == ssh }

def --env update-applications [
  ...names: string
]: oneof<nothing, list<string>> -> nothing {
  if $env not-has disp { update-containers }
  let apps: table = append [
    ...($names | default --empty [tint2])
    ...($env.disp.apps | get --optional name | compact)
  ] | uniq
    | compact
    | path basename
    | reduce --fold=[] {|app acc|
      proc --unwrap $app
      | default {
        job --pids $app
        | default []
        | first
        | if $in != null { proc --unwrap $in }
      } | prepend $acc
      | compact
      | uniq-by pid
    } | select name pid status mem
  $env.disp.apps = $apps
}

def process-info [desc: string name?: string]: nothing -> oneof<nothing, record> {
  let arg: oneof<int, string> = job --unwrap --pids $desc
    | if ($in | is-not-empty) { first } else if $name != null { pid-of $name }
    | default $desc
  match ($arg | describe) {
    int => { ps | where pid == $arg | first }
    string => { proc --unwrap $arg }
  } | if ($in | is-not-empty) and $in has status and $in.status != Zombie { }
}

def --env update-containers [
  --return # Return the value instead of setting the `$env.disp` variable
  only?: cell-path@[mstsc xvnc openbox]
]: [
  nothing -> nothing
  record<apps: list, listeners: oneof<nothing, int>> -> oneof<nothing, record>
] {
  let current: record = default { $env.disp? | default {} }
    | default [] apps
    | default null listeners
    | select --optional $.apps $.listeners
  let columns: list<cell-path> = if $only != null { [$only] } else { [$.mstsc $.xvnc $.openbox] }
  let merged: record = {
    mstsc: (process-info mstsc mstsc.exe)
    xvnc: (process-info xtigervnc Xtigervnc)
    openbox: (process-info openbox)
  } | select --optional ...$columns
    | merge $current
  if $return { return $merged } else { $env.disp = $merged }
}

def --env update-listeners []: nothing -> nothing {
  if $env not-has disp { update-containers }
  let ct: int = check-listeners | length
  if $ct > 0 { $env.disp.listeners = $ct }
}

def kill-one [
  --strict
  --wait: duration = 1sec
  --notify = true
  --errors = true
  --signal: oneof<int, string> = 'SIGTERM'
]: oneof<string, record<name: string>, int, record<pid: int>> -> nothing {
  match ($in | describe) {
    string if $in =~ '^\d+$' => { into int }
    int | string => { }
    _ if $in has name => $in.name
    _ if $in has pid => { get pid | into int }
  } | match ($in | describe) {
    int => {
      let pid: int = $in
      match $signal {
        $s if ($s | describe) == int => $s
        SIGINT => 2
        SIGKILL => 9
        _ => 15
      } | kill --quiet=(not $notify) --signal=$in $pid
    }
    string => {
      let name: string = $in
      job --kill $name
      if $strict { '--exact' } else { '--full' }
      | pkill --signal=($signal) --ignore-case $in $name
      | complete
      | match $in.exit_code {
        0 => {
          if $wait > 1ms { sleep $wait }
          if $notify { log info $"killed '($name)' process" }
        }
        1 => { log warning $"unable to kill process; no processes matched '($name)'" }
        _ if $errors => {
          get stdout | print $in
          error make --unspanned {
            msg: $'`pkill` exited with code ($in.exit_code)'
            code: 'disp::module::external_non_zero_exit_code'
            help: $"[stderr]\n($in.stderr)"
          }
        }
        _ => { log error $"`pkill` exited with code ($in.exit_code)\n[stderr]\n($in.stderr)" }
      }
    }
  }
}

const _exe: path = '/mnt/c/Windows/System32/mstsc.exe'
def spawn-mstsc [--force]: nothing -> oneof<nothing, error> {
  if (is-running mstsc.exe) {
    if not $force { notify-running mstsc.exe | return }
    'mstsc.exe' | kill-one --strict
  }
  let rdp: path = rdp-config | path expand
  if not ($rdp | path exists) { error make --unspanned 'unable to resolve RDP configuration file' }
  if not ($_exe | path exists) { error make --unspanned "unable to locate 'mstsc.exe' executable" }
  log info 'starting mstsc.exe...'
  let id: int = job spawn --description=mstsc {
    let p: string = $"(run-external wslpath '-m' $rdp err> (null-device))"
    run-external $_exe $p out+err> (null-device)
  }
  sleep 1sec
  notify-spawned mstsc $id
  update-containers mstsc
}

def is-running [name: string --options: list<string> = [--ignore-case --exact]]: nothing -> bool {
  match (pid-of --options=$options $name) {
    null => { return false }
    $pid => { ps | where pid == $pid and status != Zombie | is-not-empty }
  }
}

def pid-of [
  name: string
  --unwrap = true
  --options (-o): list<string> = [--ignore-case --exact]
]: nothing -> oneof<nothing, int, list<int>> {
  ^pgrep ...$options $name
  | complete
  | match $in.exit_code {
    1 => { return null }
    0 => {
      get stdout
      | lines
      | str trim --right
      | into int
      | if ($in | is-not-empty) and $unwrap { first } else { }
    }
    $c => {
      error make --unspanned {
        msg: $'`pgrep` exited with code ($c)'
        code: 'disp::module::external_non_zero_exit_code'
        help: $"[stderr]\n($in.stderr)"
      }
    }
  }
}

# ——— completions ——————————————————————————————————————————————————————————————

def _apps []: nothing -> list {
  scope commands | where type == external | append $env.disp.apps | get name | uniq
}
