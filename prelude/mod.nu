# /work/dev/nu/prelude/mod.nu

const module: path = path self ../config/mod.nu | path expand --strict

export use $module NU_LIB_DIRS
export-env {
  if not $nu.is-login { source-env $module }
}
