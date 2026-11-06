# Machine configuration: the override file

`conf machine-config [user|vendor]` returns the directories of a scope (`home`, `share`, `modules`, `binaries`, …);
`conf vars`, `conf dir`, `conf auto` and `conf prompt` build on it, and `use conf` loads the vendor scope into
`NU_LIB_DIRS`/`NU_PLUGIN_DIRS`/`PATH`. The library itself holds no host names and no machine paths: the defaults
derive from Nushell's own directories (`$nu.home-dir`, `$nu.data-dir`, `$nu.default-config-dir`, …), and whatever
differs on a machine comes from one file outside the repository. Setting up a new machine is "clone, then write one
file" — or nothing at all when the defaults fit.

## Location

In order of precedence:

1. `conf machine-config --file <path>` names the file for one call; `--no-file` ignores every file (the defaults and
   `--with` only — for tests and bootstrapping).
2. `$env.NU_MACHINE_CONFIG` names the file for the process. An **empty** value means "no file" (the same as
   `--no-file`): a shell started with `NU_MACHINE_CONFIG` set to the empty string (`with-env {NU_MACHINE_CONFIG: ''} { nu }`
   from Nushell, `NU_MACHINE_CONFIG= nu` from bash) runs on the plain defaults.
3. Otherwise `machine.nuon` or `machine.nu` in Nushell's config directory (`$nu.default-config-dir`:
   `~/.config/nushell` on Linux, `~\AppData\Roaming\nushell` on Windows). When both exist the lookup fails with
   `conf::machine::conflict`; keep one.

A file named by `--file` or `NU_MACHINE_CONFIG` must exist (`conf::machine::not_found`) and must end in `.nuon` or
`.nu` (`conf::machine::invalid_argument`). Nothing is cached: every `machine-config` call reads the file again.
`conf machine-config --verbose` prints the lookup (`mode`, `host`, `os`, `strategy`) and `override = <path>` or
`override = none`.

## Two forms

**`machine.nuon` — static.** A record of literals, read with `open` (about 0.1 ms). Preferred unless a value has to
be computed.

```nuon
{
  strategy: append
  user: {
    modules: [/work/ext]
    binaries: [/opt/tools/bin]
  }
  vendor: {
    modules: /srv/nupm/modules
  }
}
```

**`machine.nu` — dynamic.** A script whose `main` returns the record:

```nushell
use env from-bash

def main []: nothing -> record {
  let profile: record = from-bash --return=merge ($nu.home-dir | path join .profile)
  {user: {share: $profile.XDG_DATA_DIR, modules: [($NU_LIB_DIRS | first) ($profile.WORK | path join ext)]}}
}
```

`machine-config` runs it in a child interpreter — `nu --no-config-file --include-path <library root> --commands
"run <file> | to nuon"` (about 15 ms) — and parses the child's stdout. The script executes in-process in that child,
so `$nu`, `$env` and the library's modules (`use env from-bash`, `use conf`, …) are available; `$NU_LIB_DIRS | first`
is the library root. Only the returned record crosses the boundary, as nuon, so:

- return strings and lists of strings only (paths are strings); anything else fails validation — values that cannot
  cross as nuon do not belong in a machine file;
- stdout is the result: report on stderr (`print --stderr`), which `machine-config` passes on;
- the script receives no pipeline input — declare `def main []: nothing -> record`. A shebang such as
  `#!/usr/bin/env -S nu --stdin` is only needed to run the script by hand with input;
- the child has `NU_MACHINE_CONFIG` set to the empty string, so `conf machine-config` inside the script (directly, or
  through `use conf`'s environment block) returns the defaults instead of running the script again;
- a non-zero exit is `conf::machine::external_failure` with the child's stderr as advice; output that is not a record
  (or not nuon) is `conf::machine::invalid_argument`.

To try a script by hand: `nu --no-config-file -I <library root> -c 'run ~/.config/nushell/machine.nu'`, or
`conf machine-config --file <script> --verbose`.

## Shape

Every key is optional. Paths are strings; list keys are lists of strings.

| Key | Type | Meaning |
|---|---|---|
| `strategy` | `overwrite`, `prepend` or `append` | The default for `--strategy` |
| `user.home`, `user.share`, `user.cache`, `user.config`, `user.state`, `user.autoload` | string | User-scope directories |
| `user.modules`, `user.binaries`, `user.scripts` | list of strings | User-scope directory lists |
| `vendor.autoload`, `vendor.modules`, `vendor.binaries`, `vendor.scripts` | string | Vendor-scope directories |
| `vendor.plugins` | list of strings | Vendor plugin directories |

The record is validated with `validate rules --strict`: an undeclared key (at the root or inside `user`/`vendor`), a
wrong type or an unknown `strategy` fails with `conf::machine::invalid_argument`. The message names the file and the
first violation; the advice lists every violation (`<rule>: <hint>`). A `null` value is the same as leaving the key
out. The `--with` record has the same shape and is validated the same way (the message says `--with`).

## Precedence and strategy

Values combine lowest to highest: **defaults < override file < `--with`**. Scalars are replaced. Lists combine
according to the strategy, which is taken from the first of `--strategy`, the `--with` record's `strategy`, the
file's `strategy`, else `overwrite`:

| Strategy | `modules` with defaults `[lib cfg nupm]` and file `[ext]` |
|---|---|
| `overwrite` | `[ext]` |
| `prepend` | `[ext lib cfg nupm]` |
| `append` | `[lib cfg nupm ext]` |

Lists are deduplicated afterwards (first occurrence wins). `--host` and `--os` exist for inspection and tests: no
default depends on the hostname (it only labels `--verbose` output), and `--os` picks the OS-dependent default (the
vendor `binaries`: `/usr/bin`, or the Windows Apps directory). The file is not keyed by host — one file per machine.

## Errors

| Code | When | Message / advice |
|---|---|---|
| `conf::machine::conflict` | both `machine.nuon` and `machine.nu` exist in the config directory | names both files |
| `conf::machine::not_found` | the file named by `--file` or `NU_MACHINE_CONFIG` does not exist | names the path |
| `conf::machine::invalid_argument` | unknown mode or strategy; `--file` with `--no-file`; unsupported extension; malformed nuon; not a record; a shape violation (file or `--with`) | names the file; advice lists the violations |
| `conf::machine::external_failure` | the script exited non-zero | names the script; advice is its stderr |

A failing override fails `conf machine-config` and every explicit `conf` call that resolves the machine
configuration. `use conf` is the exception: its environment block runs at every shell start (the owner's `env.nu`),
so there a failing override is reported on stderr (`conf: the machine override file was ignored, using the
defaults: …`) and the defaults are loaded instead. Fix the file and run `conf machine-config` to see the full
error; `conf vars --no-file` and `conf machine-config --no-file` ignore the file on purpose.

## Example

`_docs/examples/machine.nu` is the script the library's former host branch became: on Linux it reads the XDG
directories and `WORK` from `~/.profile` (through `env from-bash`, with a minimal PATH so `binaries` gets the entries
the profile adds), lays `modules`/`scripts` out under `WORK` and the vendor scope under `NUPM_HOME`; on Windows it
maps the user directories to `APPDATA`/`LOCALAPPDATA`. Install it with

```nushell
cp <library root>/_docs/examples/machine.nu ($nu.default-config-dir | path join machine.nu)
conf machine-config --verbose
```

and edit the values. The conf suite (`_tests/suites/conf.nu`) runs it under a fake home and profile.
