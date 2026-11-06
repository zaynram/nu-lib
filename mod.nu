# /work/dev/nu/mod.nu
# ---
# Custom module library for my development environment.

# ——— constants ————————————————————————————————————————————————————————————————

export use conf/machine.nu [ NU_LIB_DIRS NU_PLUGIN_DIRS ]

# ——— barrels ——————————————————————————————————————————————————————————————————

module prelude {
  # Common-use barrel loader for the module library.

  # ——— commands ———————————————————————————————————————————————————————————————

  export module pman
  export module link
  export module reload
  export module edit
  export module path

  # ——— interfaces —————————————————————————————————————————————————————————————

  export use proj
  export use track
  export use time
  export use todo
  export use alarm
  export use hook
  export use mods
  export use conf
  export use env
  export use error

  # ——— bundles ————————————————————————————————————————————————————————————————

  export use windows *
  export use completion *
  export use elevate *
  export-env {
    if ($NU_LIB_DIRS | difference $env.NU_LIB_DIRS) == [] { return }
    $env.NU_LIB_DIRS ++= $NU_LIB_DIRS
  }
}

# ——— activation ———————————————————————————————————————————————————————————————

export use prelude *
