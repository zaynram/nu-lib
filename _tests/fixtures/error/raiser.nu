# A module under the repository root that raises with a derived code: `_tests::fixtures::error::raiser::go::not_found`.
use error

# Raise with a derived code (a raise cannot be the last statement of a `-> nothing` command, as with `error make`).
export def go []: nothing -> error {
  error raise 'the raiser raised' --kind not_found
}
