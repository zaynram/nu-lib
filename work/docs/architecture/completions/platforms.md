# `_platforms`

## Dependencies

1. `/work/dev/nu/completion`
   - `into completions` enhances completions with automatic wrapping and option insertion

## Implementation

```nu
use completion "into completions"
def _platforms []: nothing -> record {
  [[value description];
   [todoist 'Include items relevant to Todoist task management']
   [github 'Include items relevant to GitHub development progression']
   [all 'Include items relevant to all platforms; i.e. Todoist and GitHub']
  ] | into completions {
    case_sensitive: false
    completion_algorithm: prefix
    match_description: false
  }
}
```
