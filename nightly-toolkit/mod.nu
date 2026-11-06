#!/usr/bin/env -S nu --stdin
# Vendored for `pman` from the owner's nupm modules (~/.local/share/nupm/modules/nightly-toolkit, untracked there;
# file dated 2026-10-18, copied 2026-11-06). Only the `get-latest-nightly-build` entry point that `pman` uses is
# exported; the unused `upgrade` alias was dropped.
#
# Toolkit providing utiilities and automations for installing the latest nightly build.
#
# Reimplementation of the original nightly toolkit module.
#
# Additional Features:
# * cross-platform degradation behavior
# * more informative and actionable logging/error information
# * idempotency against the active Nushell version
# * automatic process replacement when the install destination would replace the current process executable
#
# Known Issues:
# * I have only tested this on Windows once (and changed have been made since)
# * This has never been used on MacOS or BSD operating systems

use std/log
const FILE: path = path self
const EXCLUDE: list<glob> = [`**/*.{tar.gz,zip}` `**/README.{md,txt}` **/LICENSE]
const REGEX: string = 'nu-(?<version>\d+\.\d+\.\d+-\w+\.\d+).+'

## Filters

alias is-nu-binary = do { path parse | reject parent | compact --empty | $in == {stem: nu} }
alias is-current-version = do {|version: string| $version == (version).version }

## Commands

# Install the latest nightly build of Nushell
#
# This command will
# - get the metadata of the latest build of Nushell in the nightly repo
# - interactively ask for one of them or use architecture-specific defaults
# - download the archive
# - extract the archive
# - install the `nu` binary
def --wrapped main [
  --install-dir: path # the directory where to install the `nu` binary
  --interactive # ask for the architecture to install interactively
  --full # install Nushell with all extra features enabled
  --musl # install Nushell from the MUSL builds (linux x86_64 only)
  ...rest: string # Arguments to pass to `exec nu` when replacing the current process
]: nothing -> oneof<nothing, string> {
  let build = {full: $full musl: $musl}
    | resolve-build --ask=$interactive
    | fetch-build
  let items = $build | extract-build
  let parent: path = bin $install_dir
  let target: path = $parent | path join nu
  let binary: path = if ($items | is-empty) {
    let help: string = $"install the binaries manually from '($build.dir)'"
    throw --code=missing_binaries --help-msg=$help no binaries found during collection
  } else if not ($items | any { is-nu-binary }) {
    throw --code=missing_binaries unable to locate '`nu`' binary
  } else if (is-current-version $build.version) {
    return $"(ansi bb)($build.version)(ansi rst) is already installed"
  } else if $target != $nu.current-exe {
    $items | install-items --parent=$parent
    return (success $build.version)
  } else {
    let tmp: path = mktemp --dry --suffix=__nu
    let bin: path = $items | skip until { is-nu-binary } | first
    mv --force $bin $tmp; $tmp
  }
  if ($binary | path exists) {
    report --show={path: $target} 'installing `nu` binary...'
    mv --verbose --progress $binary $target
    return (success $build.version)
  } else {
    $items | where $it != $binary | install-items --parent=$parent
    if ($build.dir | path exists) { rm --recursive --force $build.dir }
    exec $binary --execute $FILE ...$rest
  }
}

## Exports

export alias get-latest-nightly-build = main

## Helpers

def resolve-build [
  --ask = false # ask for the architecture to install interactively
]: record<musl: bool, full: bool> -> record {
  let param: record = $in
  report fetching latest releases...
  http get https://api.github.com/repos/nushell/nightly/releases
  | sort-by published_at --reverse | first | get assets
  | par-each {|it|
    get name
    | parse --regex 'nu-(?<version>\d\.\d{3}\.\d)-nightly\..-(?<arch>[a-zA-Z0-9-_]*)'
    | into record
    | merge $it
  }
  | if $ask {
    match ($in | length) {
      0 => { throw no nightly build... }
      1 => { return $in.0 }
      _ => {
        let assets: table = $in
        let prompt: string = $"(ansi cyan)Choose architecture(ansi reset):"
        let choice: oneof<string, nothing> = $assets | input list $prompt --display={ get arch }
        if ($choice | is-empty) { return 'user chose to exit' } else { $choice }
      }
    }
  } else if $param.musl and ($nu.os-info | where arch == x86_84 or name == linux | is-empty) {
    let os: string = $nu.os-info | get name arch | str join (char space)
    throw '--musl' requires to be on "'linux x86_64'," not $os --code=invalid_options
  } else if $param.full and ($nu.os-info.arch not-in [aarch64 x86_64]) {
    throw '--full' is not available for $nu.os-info.arch --code=invalid_options
  } else {
    let assets: table = $in | where name not-ends-with '.msi' and name =~ $REGEX
    let query: record = $param
      | insert os $nu.os-info.name
      | insert arch $nu.os-info.arch
    let arch: string = match $query {
      {os: linux musl: true full: true} => 'x86_64-linux-musl-full'
      {os: linux musl: true full: false} => 'x86_64-unknown-linux-musl'
      {os: linux arch: $a musl: false full: false} => $'($a)-unknown-linux-gnu'
      {os: linux arch: $a musl: false full: true} => $'($a)-linux-gnu-full'
      {os: macos arch: $a full: true} => $'($a)-darwin-full'
      {os: macos arch: $a full: false} => $'($a)-apple-darwin'
      {os: windows arch: $a full: true} => $'($a)-windows-msvc-full'
      {os: windows arch: $a full: false} => $'($a)-pc-windows-msvc'
      {os: $os} => $os
    }
    let a: oneof<nothing, record> = $assets | where name =~ $arch | last
    $a | if $in == null { throw $"unable to find build for architecture '($arch)'" } else { }
  }
}

def parse-target []: record<name: string, browser_download_url: string> -> record<name: string, url: string, version: string, extension: string> {
  let base: record = $in
  $base.name
  | match $nu.os-info.family { unix => { path parse --extension=tar.gz } _ => { path parse } }
  | reject parent stem
  | insert name $base.name
  | insert url $base.browser_download_url
  | insert version {|row|
    $row.name
    | parse --regex $REGEX
    | into record
    | get version
  }
}

def fetch-build []: record -> record<path: string, dir: string, type: string, version: string> {
  let build = $in
    | compact --empty
    | select name browser_download_url
    | parse-target
  let archive: path = temp | path join $build.name
  report --show=$build.name fetching archive...
  http get $build.url | save --progress --force $archive
  if $build.extension not-in [tar.gz zip] {
    throw unknown extension $'.($build.extension)' --help-msg=(
      $build | to nuon --serialize
      | prepend 'unable to detect archive format'
      | str join ' '
    )
  } else {
    $build | reject url
    | rename --column={name: path extension: type}
    | insert dir { $archive | path dirname }
    | update path $archive
  }
}

def extract-build []: record<path: path, type: string, dir: directory> -> list<path> {
  let build: record = $in
  let prefix: glob = $build.dir | path join ** `{nu,nu_plugin_*}`
  report --show=$build.path extracting archive...
  try {
    match $build.type {
      tar.gz => { tar xvf $build.path --directory $build.dir }
      zip => { unzip $build.path -d $build.dir }
    }
    glob $prefix --exclude=$EXCLUDE
  } catch {
    throw extraction did not succeed --code=failed_extraction
  }
}

def install-items [
  --parent (-p): oneof<nothing, directory>
]: list<path> -> oneof<nothing, string> {
  let queue: list<path> = $in
  let info: record = {destination: $parent count: ($queue | length)}
  report --show=$info proceed with installation? '(y/N):'
  try {
    match (input listen --timeout=30sec --types=[key]) {
      {code: $c} if $c not-in yY => { throw }
      {modifiers: $m} if ($m | is-not-empty) => { throw }
    }
  } catch {
    return $'(ansi rb)aborted(ansi rst)'
  }
  for bin in $queue {
    try {
      report --show=($bin | path basename) installing binary...
      cp --force --progress --verbose --update $bin $parent
    } catch {
      throw --non-fatal --code=installation_error failed to install ($bin | path basename)
    }
  }
}

## Utilities

def bin [
  override: oneof<nothing, path>
]: nothing -> directory {
  let dir: path = $override
    | default { $nu.current-exe | path dirname }
    | path expand --no-symlink
  if $dir not-has $nu.home-dir and not (is-admin) {
    error make --unspanned {
      msg: $"elevation is required to install to '($dir)'"
      help: $'rerun this script with elevated privileges'
    }
  } else if ($dir | path type) != dir {
    mkdir --verbose $dir
  }
  return $dir
}

def temp []: nothing -> path {
  let temp = $nu
    | transpose key value
    | where key =~ ^temp-
    | get --optional 0.value
    | default { mktemp --directory }
    | path join (random chars --length 10)

  report --show=$temp preparing temporary directory...
  mkdir --verbose $temp
  return $temp
}

## Logging / Errors

def throw [
  ...msg: string
  --code: oneof<nothing, string> = unexpected_internal_error
  --help-msg: string
  --non-fatal (-n) # Print an error message but allow execution to continue
]: oneof<nothing, record, error> -> error {
  if $non_fatal {
    let text: string = [
      ($msg | str join ' ')
      (if $code != null { $"  | (ansi rb)code(ansi rst): ($code)" })
      (if $help_msg != null { $"  | (ansi rb)help(ansi rst): ($help_msg)" })
    ] | compact | str join "\n"
    log error $text
  } else {
    error make --unspanned (
      {
        msg: ($msg | str join ' ')
        code: $"(ansi rb)($code)(ansi rst)"
        help: $help_msg
        inner: ($in | append [])
      } | compact --empty
    )
  }
}

def report [
  ...words: string
  --show: oneof<path, record>
]: nothing -> nothing {
  let type: string = $show | describe | split words | first
  let text: string = $words | flatten | str join ' ' | match $type {
      nothing => { append [] }
      string => { append $"\n ↳ (ansi c)'($show)'(ansi rst)" }
      record => {
        let text: string = $in
        $show | items {|k v|
          $"\n ↳ (ansi gb)($k)(ansi rst) (ansi c)'($v)'(ansi rst)"
        } | prepend $text
      }
    } | str join
  log info $text
}

def success [version: string]: nothing -> string {
  $"(ansi gb)install complete(ansi rst) \((ansi c)`nu`(ansi rst) v($version))"
}
