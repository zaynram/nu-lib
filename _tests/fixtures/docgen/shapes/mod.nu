# Edge shapes for the collector: overloads and submodules without commands of their own.

# A command with two signatures.
export def multi [
  --loud # shout it
]: [nothing -> string, int -> string] { if $loud { 'X' } else { 'x' } }

# A submodule whose name needs quoting in a `use` statement.
export module "odd name" {
  export def hi []: nothing -> string { 'hi' }
}

# A submodule with only constants.
export module consts {
  export const C: int = 1
}

# A submodule that only holds another submodule.
export module holder {
  export module inner {
    export def deep []: nothing -> int { 3 }
  }
}
