# `work drift`

## Dependencies

1. `/work/dev/nu/proj`
   - `proj list` provides project indexing and repository metadata
2. `/work/dev/nu/todo`
   - `todo projects` provides task project names, IDs, and URLs
   - `todo list` provides task indexing and metadata

## Completions

- [`_project_names`](../completions/project_names.md)
- [`_platforms`](../completions/platforms.md)

## Helpers

```nu
# Return a boolean indicating whether a task's project has a remote host.
def has-remote [
  name: oneof<nothing, string> # Name filter from a caller's scope
  projects: table # Project data from a caller's scope
]: record -> bool {
  let task: record;
  let name: oneof<nothing, string> = if $name != null { $name } else { $task.project? }
  if $name == null or $projs.name not-has $name { return false }
  let proj: oneof<nothing, record> = $projects | where name == $name | compact | first
  $proj != null and $proj has host and $proj.host != ''
}
```

## Implementation

```nu
# Preset action strings for consistent drift fix entries.
const ACTIONS: list<string> = [...]
# Regex filter for discerning automatically fixable fix actions
const FIXABLE: string = '...'

# Itemize the items with drift across the management platforms.
export def "work drift" [
  name?: string@_project_names
  # Filter the projects to include drift entries for by name
  --platform(-p): string@_platforms = 'all'
  # Only include drift that can be fixed in this platform
  --regex(-r): string
  # Filter the task content (slugs) to include in the drift summary
  --auto-fix(-a) = true
  # Automatically handle convergent (single-fix) drift entries
]: nothing -> table<item: string, context: string, fixes: table<platform: string, action: string>> {
  # Gather relevant task data respective to filter parameters
  let tasks = todo list --project=$name | if $regex == null {  } else { where content =~ $regex }
  # Filter project data to those relevant to the task set
  let projs = proj list | where name in $tasks.project
  # Gather remote data for projects with remotes from task description pointers.
  let items = $tasks
    | where ($it | has-remote $name $projs)
    | par-each {|t|
      let slug: string = $t.content
      let desc: string = $t.description
      # ... gather relevant field data from description's pointer URL
      # ... if it exists, otherwise drift is the lack of the pointer
      # ... if the pointer URL does resolve, derive drift through
      # ... data comparison across platforms and return drift rows
    } | match $platform {
      todoist | github => (where ($it.fixes | any platform =~ $platform))
      all | _ => ()
    } | if $auto_fix {
      update $.fixes {|row|
        if ($in | length) != 1 or ($in.0.action) !~ $FIXABLE { return $in }
        # ... fix the convergent item and return an empty list
        return []
      } | where fixes != []
    } else {
      return $in
    }
  }
}
```
