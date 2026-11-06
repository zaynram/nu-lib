# Workspace related utility methods.

# nu-lint-ignore-file: missing_output_type, missing_in_type

# ——— imports ——————————————————————————————————————————————————————————————————

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
  if not ($file | path exists) { error make --unspanned {msg: $"file not found: '($file)'"} }
  let ext: string = $file | path parse | get $.extension
  if $BUMPABLE not-has $ext { error make --unspanned {msg: $"unsupported file extension: '($ext)'"} }
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
  --keep-order (-k)
  # Mapped to the same flag on `par-each`
]: table<file: path, cell: cell-path> -> table<file: path, cell: cell-path, prev: any, curr: any> {
  let rows: table = $in
  let wanted: any = $spec | if $in != null { into semver }
  $rows | par-each --keep-order=$keep_order {|row|
    let type: string = try { $row.file | ensure-bumpable } catch {|err|
      if $skip { return {...$row prev: null curr: null} }
      error make --unspanned {msg: $err.msg}
    }
    let data: any = open $row.file
    let curr = $data
      | try { get $row.cell } catch { error make --unspanned {msg: $"invalid version cell path: ($row.cell)"} }
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
