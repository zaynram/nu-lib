# Test seam for `validate`: the module under test, assertions, and the runner's `skip`, re-exported for every suite.
#
# The module comes first: exported names are predeclared before later imports parse, and the runner's
# `skip [reason]` would otherwise shadow the builtin `skip` inside modules parsed after it. The library root is
# on the children's include path through the repository's `nutest.nuon`.
export use ../../validate
export use std/assert
export use test skip
