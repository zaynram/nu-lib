# A tiny module exercising every metadata surface the collector extracts.

# Greet someone by name.
#
# The long form: greetings default to casual unless --polite is given.
@example "greet politely" { greet world --polite } --result "Hello, world!"
@search-terms hello salutation
export def greet [
  name: string # who to greet
  --polite (-p) # use a formal greeting
  --punctuation: string = '!' # trailing punctuation
]: nothing -> string {
  $"(if $polite { 'Hello' } else { 'hi' }), ($name)($punctuation)"
}

# Sum whatever numbers arrive on the pipeline.
export def total [
  ...extra: int # additional numbers to include
]: list<int> -> int {
  append $extra | math sum
}

# Describe the sample module itself.
export def main []: nothing -> string { 'sample' }

# A private helper that must stay invisible to the collector.
def hidden []: nothing -> nothing { }
