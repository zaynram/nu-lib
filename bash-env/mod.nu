#!/usr/bin/env -S nu --no-config-file --no-std-lib
# Vendored copy of `bash-env` (MIT, see LICENSE): https://github.com/zaynram/bash-env-nushell, a fork of
# tesujimath/bash-env-nushell. Source: /work/ext/bash-env at 6d0a7e7 plus its uncommitted local changes, copied
# 2026-11-06; `bin/bash-env-json` is upstream's script (v0.10.1). Only change: the script is resolved from `bin/`.
# nu-lint-ignore-file: spread_list_to_external, unhandled_external_error, add_doc_comment_exported_fn, script_export_main, default_empty_string_masks_missing
const FILE: path = path self | path expand --strict
const BASH_ENV_JSON: path = $FILE | path dirname | path join bin bash-env-json
const RETURN_ENUM: list<string> = [env shellvars merge preserve]
# Bash environment adapter for nushell to read variables and capture function environment changes.
@example "load an environment variable" { bash-env --content="export N=10" --load; $env | select N } --result {N: 10}
@example "capture a shell variable" { bash-env --content="ABC=123" --return=merge } --result {ABC: 123}
@example "avoid capturing an unexported variable" { bash-env --content="ABC=123" --return=env } --result {}
@example "capture function environment effects" {
  let script: path = mktemp --dry --suffix .env
  [
    "export A=0"
    "export B=0"
    "function showcase1() { export A=1; export B=1; S1='showcase1 shell var'; }"
    "function showcase2() { export A=2; export B=2; S2='showcase2 shell var'; }"
  ] | save $script
  bash-env --execute=[showcase1 showcase2] $script
} --result {
  env: {B: 0 A: 0}
  shellvars: {}
  fn: {
    showcase1: {env: {B: 1 A: 1} shellvars: {S1: "showcase1 shell var"}}
    showcase2: {env: {B: 2 A: 2} shellvars: {S2: "showcase2 shell var"}}
  }
}
export def --env main [
  file?: path # Path to bash script to source environment changes from (ignored if pipeline input is not `null`)
  --execute: list<string> = [] # Names of functions to execute and capture environment changes from (implies `--return=preserve`)
  --content (-c): string # File contents to evaluate and capture environment changes from
  --load (-l) # Automatically load the environment variables (noop if `--serialize` is passed; does not include shellvars)
  --return (-i): string@$RETURN_ENUM = merge # Capture all or a subset of the shell variables (does not apply if `--exec` is not empty)
  --serialize (-s) # Serialize the output record to NUON before returning
  --prune (-p) = true # Prune `null` and empty variables from the output record
]: nothing -> oneof<string, record, record<env: record, shellvars: record, fn: record>> {
  if not ($BASH_ENV_JSON | path exists) { error make --unspanned $"unable to resolve `bash-env-json` at '($BASH_ENV_JSON)'" }
  let raw: bool = $return == preserve or $execute != []
  let out: oneof<string, record> = match ($content | describe) {
    _ if ($content | is-empty) and $file == null => (error make --unspanned 'no content or path was provided')
    nothing if not ($file | path exists) => (error make --unspanned $"file not found: '($file)'")
    nothing => (open --raw $file)
    string => $content
  } | run-external $BASH_ENV_JSON ...(match ($execute | str join ',') { '' => [] $e => [--shellfns $e] })
    | complete
    | default '' stderr stdout
    | if $in.exit_code == 0 {
      let stdout: string = $in.stdout
      # NUON is JSON compatible so skip the rest if we don't need the serialization round trip
      if $serialize and $raw { return $stdout }
      let json: record = try { $stdout | from json | default {} env shellvars | reject $.meta!? } catch {
        error make --unspanned $"JSON decode error parsing: '($stdout)'"
      }
      if $load { load-env $json.env!? }
      if $raw { return $json }
      match $return { env | shellvars => ($json | get $return) merge => ($json.shellvars! | merge $json.env!) }
      | if $prune { compact --empty } else { }
      | if $serialize { to nuon --serialize } else { }
    } else {
      error make --unspanned {
        msg: $'bash-env-json exited with code ($in.exit_code)'
        help: ($in | format pattern $"[stdout]\n{stdout}\n[stderr]\n{stderr}")
      }
    }
  return $out
}
