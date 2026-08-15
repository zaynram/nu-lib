# ——— imports —————————————————————————————————————————————————————————————————

export use vendor
export use user
export use util *

# ——— constants ————————————————————————————————————————————————————————————————

export const NU_LIB_DIRS: list<path> = [
  (path self .)
  $user.modules
  $vendor.modules
]
export const NU_PLUGIN_DIRS: list<path> = [
  $user.plugins
  $vendor.plugins
]

# ——— environment ——————————————————————————————————————————————————————————————

export-env {
  if $env.pid? == null {
    source-env user/mod.nu
    source-env repo/mod.nu
    path add ...[
      $vendor.scripts
      /home/linuxbrew/.linuxbrew/bin
      ...(glob $"($user.home)/**/bin" --exclude=[**/.vscode-server-insiders/**] --depth=2)
      ...(glob $"($user.scripts)/**" --exclude=[**/_internal/**])
    ]
    $env
    | select --optional NU_LIB_DIRS NU_PLUGIN_DIRS
    | upsert NU_LIB_DIRS { append $NU_LIB_DIRS }
    | upsert NU_PLUGIN_DIRS { append $NU_PLUGIN_DIRS }
    | upsert REPO { default {} | upsert discovery true | default [] path }
    | load-env
    vendor init
    $nu | select pid | load-env
  }
}
