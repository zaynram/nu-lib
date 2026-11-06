# Removing variables: an inherited one (env: null), unexporting one (moves to the shell variables), a bash shell
# variable (shellvars: null), and one set and unset within the script (not reported).
unset SBFB_GONE
export -n SBFB_UNEX
unset OPTERR
SBFB_TEMP=1
unset SBFB_TEMP
