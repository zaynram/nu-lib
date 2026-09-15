# Test seam for `track`: the modules under test, assertions, and the runner's `skip`, re-exported for every suite.
#
# The modules come first: exported names are predeclared before later imports parse, and the runner's
# `skip [reason]` would otherwise shadow the builtin `skip` inside modules parsed after it.
export use (path self ..)
export use (path self ../../time)
export use std/assert
export use ($nu.data-dir | path basename --replace nupm/modules/test) skip
