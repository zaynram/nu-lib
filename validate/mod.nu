# Suite of validation tools to assist with custom command definitions and parameter validation.
#
# Return values are closures intentionally:
# - Calling `error make` from a nested scope causes error duplication as it propagates upwards.
# - Returning raw details records would require each consumer to typecheck the return value
# - Closure values allow for ergonomic usage - `... | validate string <regex> | do $in`
# - Validation error reporting can be handled in a single line, with re-assignment support for valid items.

# Validate a string using pattern matching with regular expressions.
@category test
@example 'validate a string matches a regex pattern' { do ('abc' | validate string \w+) } --result=abc
@example 'validate a string is an enum member' { do ('x' | validate string --enum=[x y z]) } --result=x
@example 'validate a string does not match a pattern' { do ('nan' | validate string --not '\d+') } --result='nan'
export def string [
  regex?: string
  # Regex expression to validate the string with (`$in =~ $regex`)
  --not (-n)
  # Invert the validation behavior (`$in !~ $regex`; `$enum not-has $in`)
  --enum: list<string> = []
  # List of valid values to test for membership with the input value (`$enum has $in`)
  --message: string = 'the provided string is invalid'
  # Error message for validation failures
  --code: string = 'internal::validate::string_unmatched_regex'
  # Error code for validation failures
  --labels: table<text: string, span: record> = []
  # Error labels for validation errors; the input and regex pattern will be included if this is empty
  --inner: list<record> = []
  # Inner error(s) to include in the error details for validation errors
]: string -> closure {
  if (($regex != null and $in =~ $regex) or $enum has $in) != $not { let s: string; {|| $s } } else {
    let value: record = metadata | {text: string span: $in.span}
    let check: record = if $regex != null { {text: regex span: (metadata $regex).span} } else { {text: enum span: (metadata $enum).span} }
    let labels: table<text: string, span: record> = $labels | default --empty [$value $check]
    {|| error make ({msg: $message code: $code labels: $labels inner: $inner} | compact --empty) }
  }
}
