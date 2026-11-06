# The last command fails, so the script fails; its stderr is the cause.
echo 'first problem' >&2
echo 'second problem' >&2
export SBFB_X=1
false
