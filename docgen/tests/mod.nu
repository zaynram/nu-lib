# Docgen-specific test seam: assertions, fixture locations, and the module
# under test, re-exported for every suite.
export use std/assert
export use ../mod.nu collect

export const FIXTURES: path = path self ./fixtures
