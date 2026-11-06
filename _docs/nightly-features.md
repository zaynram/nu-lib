# Nightly features the library relies on, and how to find new ones

The library tracks the latest Nushell nightly, and the website (nushell.sh) is generated per stable release, so
features the library uses are often documented only *in the binary*. This page records the ones in use and the
method that finds new ones; refresh it when the nightly moves.

## In use (as of 0.116.2-nightly.33)

| Feature | Where the library uses it | In-binary docs |
|---|---|---|
| `record each` / `record where` | record mapping and filtering everywhere (CLAUDE.md "Data shaping"); 7×/3× faster than `items … \| into record` | `help record each` |
| `from dotenv` (and converting `load-env`) | `env parse` (formerly `env dotenv`) is a thin wrapper; `env from-bash --load` relies on `load-env` applying `ENV_CONVERSIONS` | `help from dotenv`, `help load-env` |
| `config use-colors` | every ANSI colour goes through `style` (`colors`/`paint`), which asks it | `help config use-colors` |
| `view span`, `view files` | `error raise` derives codes from the raise site without reading disk | `help view span` |
| `run <script>` keyword | `conf machine-config` runs a `.nu` override in a child with `run … \| to nuon` (typed result; `run` needs a parse-time constant path, so it cannot run a user path in-process) | `help run` |
| experimental options on by default: `pipefail`, `enforce-runtime-annotations`, `reorder-cell-paths` | `complete`-based wrappers (`command`), typed `let` everywhere | `debug experimental-options` |
| REPL: `status_line.*`, `$ans`, `hinter.closure` | not used by the library; worth knowing (the status line previews const pipelines live) | `config nu --doc` |

Removed since 0.116.0 and not used: `date format`, `filter`, `let-env`, `get/select/reject --ignore-errors`.

## Finding new ones

The binary describes itself: dump its self-description under two versions and diff.

```nushell
# inventory.nu — run it with each `nu` binary: nu --no-config-file inventory.nu <out-dir>
def main [out: path] {
  let keys = config nu --doc | lines | where $it starts-with '$env.config.' | parse --regex '^\$env\.config\.(?<key>[\w.-]+)' | get key | sort
  $keys | save --force ($out | path join $"config-keys-((version).version).txt")
  scope commands | select name type signatures | sort-by name | to nuon | save --force ($out | path join $"commands-((version).version).nuon")
  $nu | columns | sort | save --force ($out | path join $"nu-keys-((version).version).txt")
}
```

Then compare the two dumps: config keys and command names with `where $it not-in $old`, flags per command from
`signatures` (`parameter_type =~ 'named|switch'`), and `debug experimental-options` for in-progress features.
A stable baseline binary comes from the release tarball (`nu-<version>-x86_64-unknown-linux-gnu.tar.gz`); the
upstream commit titles between two tags come from
`http get https://api.github.com/repos/nushell/nushell/compare/<tag>...main`. The last full diff (0.116.0 →
nightly.33) found 10 new config keys, 13 new commands, 3 removed commands and 23 commands with changed flags.
