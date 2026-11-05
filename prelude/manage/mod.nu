# /work/dev/nu/prelude/manage/mod.nu

# export module work
export module proj
export module time
export module todo
export module alarm
export module track

export-env { if $nu.is-interactive and $nu.is-login { use proj; use track } }
