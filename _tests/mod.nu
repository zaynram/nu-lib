# Shared test seam for every suite in `_tests/suites`: assertions, the runner's helpers, and fixture locations.
#
# Suites load it with `use ../mod.nu *` AFTER importing the module(s) they test:
#
#   use validate
#   use ../mod.nu *
#
# Order matters. The runner's `skip [reason]` shadows the builtin `skip` inside every module parsed after it is
# imported (Nushell leaks imported names into later module parses), so a module imported after the seam breaks
# wherever it uses `skip`. Modules resolve from the repository root, which `nutest.nuon` puts on the include
# path of every test child.

export use std/assert
export use test [ skip with-sandbox sandboxed ]

# The repository root.
export const ROOT: path = path self ..
# Fixture files, one directory per module: `$FIXTURES | path join docgen`.
export const FIXTURES: path = path self fixtures
