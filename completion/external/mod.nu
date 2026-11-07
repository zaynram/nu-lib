# DEPRECATED: compatibility shim for `completion/local`; import that module instead.
#
# Kept so existing imports such as `use completion/external set-completer` keep working: it re-exports the
# external-completer commands of `completion/local` under their old names and, on a direct `use` of this module,
# runs `completion/local`'s environment set-up. It adds nothing of its own and will be removed.

# ——— imports ——————————————————————————————————————————————————————————————————

export use ../local [
  fish-complete "fish-complete parse-output" carapace-complete "carapace-complete runtime-env" set-completer run-completer
]

# ——— environment ——————————————————————————————————————————————————————————————

export-env { use ../local }
