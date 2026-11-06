# Workspace related utility methods.

# nu-lint-ignore-file: missing_output_type, missing_in_type

# ——— imports ——————————————————————————————————————————————————————————————————

use error
use std/util null-device

# ——— constants ————————————————————————————————————————————————————————————————

export const LEVEL: list<string> = [major minor patch alpha beta rc release]
const BUMPABLE: list<string> = [csv html json md kdl msgpack ndnuon nuon text toml msgpackz plist txt tsv yaml xml yml]

# ——— aliases ——————————————————————————————————————————————————————————————————

# Hide the `__workspace__` overlay (an error unless the user's config created it).
export alias deactivate = overlay hide __workspace__
# Leave and re-enter the current directory, re-running `env_change.PWD` hooks.
export alias reactivate = do --env { let cwd: path = pwd; cd $nu.temp-dir; cd $cwd }

# ——— definitions ——————————————————————————————————————————————————————————————

# The file's extension, or an error when the file does not exist or `save` cannot write its format.
def ensure-bumpable []: path -> oneof<string, error> {
  let file: path = $in
  if not ($file | path exists) { error raise $"file not found: '($file)'" --kind not_found }
  let ext: string = $file | path parse | get $.extension
  if $BUMPABLE not-has $ext {
    error raise $"unsupported file extension: '($ext)'" ...{
      kind: unsupported
      advice: $"`save` writes: ($BUMPABLE | str join ', ')"
    }
  }
  return $ext
}

# Bump the version stored in one or more files, and write the new version back.
#
# Each input row names a file and the cell-path of its version string. The file is re-serialized in Nushell's
# format for its extension (`save`); `.toml` files are then formatted with `tombi` and `.json` files with
# `dprint`, when installed (their failures are ignored). `prev` and `curr` are semver values (`into string` them
# to serialize).
@category system
export def bump [
  target: string@$LEVEL = 'patch'
  # The level to bump in the version
  --spec (-s): string
  # An exact version to set instead of bumping (must be valid semver)
  --meta (-m): string
  # Build metadata to set instead of preserving the existing
  --test (-t)
  # Return the version bump data without writing anything to disk
  --skip (-S) = true
  # Return missing files and unsupported formats with null `prev`/`curr` (the default); `--skip=false` raises
]: table<file: path, cell: cell-path> -> table<file: path, cell: cell-path, prev: any, curr: any> {
  let rows: table = $in
  let wanted: any = $spec | if $in != null { into semver }
  # Sequential: two rows may name the same file, and parallel writes would lose one of the updates.
  $rows | each {|row|
    # without `--skip`, the error of `ensure-bumpable` is the caller's
    let type: oneof<nothing, string> = if $skip { try { $row.file | ensure-bumpable } catch { null } } else { $row.file | ensure-bumpable }
    if $type == null { return {...$row prev: null curr: null} }
    let data: any = open $row.file
    let curr = $data
      | try { get $row.cell } catch {|e|
        $e | error raise $"no version at '($row.cell)' in '($row.file)'" --kind not_found
      }
      | into semver
    let next = $wanted | default (
        $curr | semver bump --build-metadata=$meta --loose --preserve-build-metadata $target
      )
    if not $test and ($curr != $next) {
      $data | update $row.cell ($next | into string) | save --force $row.file
      match $type {
        toml => { do --ignore-errors { tombi format $row.file out+err> (null-device) } }
        json => { do --ignore-errors { dprint fmt $row.file out+err> (null-device) } }
      }
    }
    return {...$row prev: $curr curr: $next}
  }
}
