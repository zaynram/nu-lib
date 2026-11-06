# The vendored `nightly-toolkit` module (light coverage of vendored code): `test _tests/suites/nightly-toolkit.nu`.
#
# Its only entry point downloads and installs a Nushell build, so it is never run here.
use nightly-toolkit
use ../mod.nu *

def "test only the installer entry point is exported" []: nothing -> nothing {
  let names: list<string> = (scope aliases | get name) ++ (scope commands | get name) | where $it starts-with 'nightly-toolkit'
  assert equal $names ['nightly-toolkit get-latest-nightly-build'] 'just get-latest-nightly-build'
}

def "test the installer documents its flags" []: nothing -> nothing {
  let text: string = help nightly-toolkit get-latest-nightly-build | ansi strip
  assert ($text =~ 'install-dir') 'the alias resolves to the installer and its --install-dir flag'
}
