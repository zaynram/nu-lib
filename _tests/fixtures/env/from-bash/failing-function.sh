# A function that fails after another succeeded.
ok() { export SBFB_OK=1; }
bad() { echo 'bad thing' >&2; echo 'more' >&2; return 3; }
