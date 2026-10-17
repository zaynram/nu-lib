# /work/dev/nu/prelude/mod.nu

use ../config [ USER VENDOR vars ]

export const NU_LIB_DIRS: list<path> = [(path self ..) $USER.modules $VENDOR.modules]
export const NU_PLUGIN_DIRS: list<path> = [$USER.plugins $VENDOR.plugins]

# Initialize the shell environment variables for the internal module library.
export def --env env [
  --load (-l)
  # Load the environment into the current process, if not done so already
  --show (-s)
  # Return the environment variables, as a record
]: oneof<nothing, record> -> oneof<nothing, record> {
  let e: record = default {}
    | upsert NU_LIB_DIRS { default $env.NU_LIB_DIRS? | append $NU_LIB_DIRS | uniq }
    | upsert NU_PLUGIN_DIRS { default $env.NU_PLUGIN_DIRS? | append $NU_PLUGIN_DIRS | uniq }
  if $load { $e | load-env }
  if $show or not $load { return $e }
}

export-env { vars --vendor | env --load }
