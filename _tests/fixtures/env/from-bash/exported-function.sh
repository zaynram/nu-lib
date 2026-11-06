# Exported functions (BASH_FUNC_*) are never reported.
f() { :; }
export -f f
export SBFB_A=1
