# `_project_names`

## Dependencies

1. `/work/dev/nu/proj`
   - `proj list` provides project indexing and repository metadata
2. `/work/dev/nu/completion`
   - `into completions` enhances completions with automatic wrapping and option insertion

## Implementation

```nu
use proj
use completion "into completions"
def _project_names []: nothing -> record {
  proj list | par-each {||
    compact --empty | match $in {
      {name: $n repo: $r vcs: git} => {value: $n description: $r}
      {name: $n path: $p} => {value: $n description: $p}
    }
  } | into completions {
    case_sensitive: false
    completion_algorithm: fuzzy
    match_description: true
  }
}
```
