# Unexported shell variables: plain, arrays (first element), a global integer, a readonly value, and a variable
# declared without -g (local to the function the script is sourced in, so it is not captured).
SBFB_PLAIN=plain
SBFB_ARRAY=(first second)
declare -gi SBFB_INT=3+4
readonly SBFB_RO=fixed
declare SBFB_LOCAL=lost
export SBFB_EXPORTED=exported
