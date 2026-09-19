use ../config

export const NU_LIB_DIRS: list<path> = [(path self ..) $config.USER.modules $config.VENDOR.modules]
export const NU_PLUGIN_DIRS: list<path> = [$config.USER.plugins $config.VENDOR.plugins]

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
    | merge (config vars --vendor --show)
  if $load { $e | load-env }
  if $show or not $load { return $e }
}

export-env { env --load }
