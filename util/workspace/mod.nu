# Workspace related utility methods.

# nu-lint-ignore-file: missing_output_type, missing_in_type

# ——— imports ——————————————————————————————————————————————————————————————————

use std/util null-device

# ——— constants ————————————————————————————————————————————————————————————————

export const LEVEL: list<string> = [major minor patch alpha beta rc release]
const BUMPABLE: list<string> = [csv html json md kdl msgpack ndnuon nuon text toml msgpackz plist txt tsv yaml xml yml]

# ——— aliases ——————————————————————————————————————————————————————————————————

export alias deactivate = overlay hide __workspace__
export alias reactivate = do --env { let cwd: path = pwd; cd $nu.temp-dir; cd $cwd }

# ——— definitions ——————————————————————————————————————————————————————————————

def ensure-bumpable []: path -> oneof<string, error> {
  let ext: string = path parse | get $.extension
  if not ($in | path exists) { error make --unspanned $"file not found: '($in)'" }
  if $BUMPABLE not-has $ext { error make --unspanned $"unsupported file extension: '($ext)'" }
  return $ext
}

# Bump the version for the server and update the relevant files.
#
# This function will re-format files into Nushell's native serialization format for the file type.
# ---
export def bump [
  target: string@$LEVEL = 'patch'
  # The level to bump in the version
  --spec (-s): string
  # An exact string to set as the current version
  --meta (-m): string
  # Build metadata to set instead of preserving the existing
  --test (-t)
  # Return the version bump data without writing anything to disk
  --skip (-S) = true
  # Skip missing files and files with unsupported formats (instead of raising an error)
  --keep-order (-k)
  # Mapped to the same flag on `par-each`
]: table<file: path, cell: cell-path> -> table<file: path, cell: cell-path, prev: any, curr: any> {
  par-each --keep-order=$keep_order {|row|
    let type: string = try { get $.file | ensure-bumpable } catch {|err|
      if $skip { return {...$row prev: null curr: null} }
      error make $err.details
    }
    let data: record = open $row.file
    let curr = $data
      | try { get $row.cell } catch { error make $"invalid version cell path: ($row.cell)" }
      | into semver
    let next = $spec | default (
        $curr | semver bump --build-metadata=$meta --loose --preserve-build-metadata $target
      )
    if not $test and ($curr != $next) {
      $data | update $row.cell ($next | into string) | save --force $row.file
      match $type {
        toml => {|| tombi format $row.file out+err> (null-device) }
        json => {|| dprint fmt $row.file out+err> (null-device) }
      } | do --ignore-errors $in
    }
    return {...$row prev: $curr curr: $next}
  }
}
