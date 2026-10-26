# /work/dev/nu/prelude/mod.nu

export use config/ NU_LIB_DIRS

export-env {
  const ROOT: path = path self .. | path expand --strict
  if $env.NU_LIB_DIRS has $ROOT { return }
  source-env ($ROOT | path join config mod.nu)
  $env.NU_LIB_DIRS ++= [$ROOT]
}
