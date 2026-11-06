# Test seam for `validate`: the module under test, assertions, and the runner's `skip`, re-exported for every suite.
#
# The module comes first: exported names are predeclared before later imports parse, and the runner's
# `skip [reason]` would otherwise shadow the builtin `skip` inside modules parsed after it.
const root = path self ../.. | path expand
export use ($root | path join validate)
export use std/assert
export use test skip
export-env { use test register; register $root }
