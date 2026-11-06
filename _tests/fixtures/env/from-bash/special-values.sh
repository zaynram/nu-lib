# Values that need escaping or careful splitting, exported and as shell variables.
export SBFB_NEWLINE=$'first\nsecond\n'
export SBFB_QUOTES=$'it\'s "quoted" \\ back'
export SBFB_EQUALS='k=v=w'
export SBFB_DOUBLE_EQUALS='a=='
export SBFB_LEADING_EQUALS='=x'
export SBFB_UNICODE='héllo wörld ✓ 日本'
export SBFB_SPACES='  padded  '
export SBFB_TAB_CR=$'a\tb\rc'
export SBFB_SHELL='$HOME `cmd` * ? [x] ~'
SBFB_SV_NEWLINE=$'one\ntwo'
SBFB_SV_QUOTES="say \"hi\" it's"
SBFB_SV_EQUALS='x=y'
