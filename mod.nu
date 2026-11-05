# /work/dev/nu/mod.nu
# ---
# Custom module library for my development environment.

const prelude: path = path self prelude/mod.nu | path expand --strict
const windows: path = path self windows/mod.nu | path expand --strict

export use $prelude [ var log ]
use $prelude [ tools shell manage ]

export use tools *
export use shell *
export use manage *

export-env {
  if $nu.os-info.name == windows or not $nu.is-login { return }
  if ($env.path! | any $it =~ '^/mnt/\w{1}/') { source-env $windows }
}
