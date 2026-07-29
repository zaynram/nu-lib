use ../mod.nu NU_LIB_DIRS

use ../util reload
export alias rl = reload

export alias rst = zellij action override-layout default

export alias ll = ls --long
export alias lf = ls --full-paths
export alias la = ls --all
export alias ld = ls --directory
export alias pj = path join

export alias ntu = do { use nightly-toolkit; nightly-toolkit upgrade }
export alias dev = do --env {|q: string = code| cd (zoxide query $q | to text | str trim) }
export alias zbg = do {|s: string ..._: string| zellij attach $s --create-background ...$_ }
export alias zjk = zellij kill-session

export alias copy = do { clip copy --show | win32yank -i }
export alias paste = win32yank -o --lf
export alias stamp = do { date now | format date %+ | copy }
