# ——— imports —————————————————————————————————————————————————————————————————

use experimental set-options
export use user
export use vendor

# ——— constants ———————————————————————————————————————————————————————————————

export const NU_LIB_DIRS: list<path> = [
  $user.scripts
  $user.modules
  $user.common
  $vendor.modules
]

export const NU_PLUGIN_DIRS: list<path> = [
  $user.plugins
  $vendor.plugins
]

# ——— definitions —————————————————————————————————————————————————————————————

# Initialize the shell session.
@category shells
export def startup []: nothing -> nothing {
  vendor init
  fortune | ansi gradient --fgstart 0x40c9ff --fgend 0xe81cff | print
  set-options
}
