# expose.nu — turn nushell command signatures into LLM tool definitions
#
# purpose: expose your own nu commands to an LLM for calling (function calling / tool use).
# the output is the Anthropic Messages API tools array format:
#   [{name, description, input_schema}, ...]
# OpenAI's tools format differs only by a {"type":"function","function":{...}} wrapper.
#
#   use expose.nu
#
#   expose from-module calc | to json -r
#   expose from-commands ["agent chat"] --snake | to json -r
#
# limits:
#   - parameters taken from a closure/block are lost; if what is lost is a "required positional
#     parameter", the whole command is excluded —— an LLM cannot construct a nu closure, so keeping it would only mislead
#   - oneof<...> union types degrade to "unconstrained" (empty schema)
#   - only modules already `use`d are recognized

# nu's syntax_shape → JSON Schema fragment
#
# syntax_shape is parameterised (list<int> / table<a: int> / record<...>),
# and nested (list<oneof<string, binary>>), so it is handled recursively by prefix
def shape->schema [s: any]: nothing -> record {
  if $s == null { return {} }
  let s = ($s | into string)

  if $s == "any"       { return {} }
  if $s == "nothing"   { return {type: "null"} }
  if $s == "bool"      { return {type: "boolean"} }
  if $s == "int"       { return {type: "integer"} }
  if $s == "float"     { return {type: "number"} }
  if $s == "number"    { return {type: "number"} }
  if $s == "string"    { return {type: "string"} }
  if $s == "datetime"  { return {type: "string", format: "date-time"} }
  if $s == "binary"    { return {type: "string", contentEncoding: "base64"} }
  if $s == "duration"  { return {type: "integer", description: "nanoseconds, 1 second = 1000000000"} }
  if $s == "filesize"  { return {type: "integer", description: "bytes"} }
  if $s == "cell-path" { return {type: "string"} }
  if $s == "path"      { return {type: "string"} }
  if $s == "directory" { return {type: "string"} }
  if $s == "glob"      { return {type: "string"} }
  if $s == "range"     { return {type: "array", items: {type: "integer"}} }

  if ($s | str starts-with "list<") {
    let inner = ($s | str replace -r '^list<' '' | str replace -r '>$' '')
    return {type: "array", items: (shape->schema $inner)}
  }

  if ($s | str starts-with "table")  { return {type: "array"} }
  if ($s | str starts-with "record") { return {type: "object"} }

  # union types are left unconstrained, the caller describes them
  if ($s | str starts-with "oneof<") { return {} }

  # closures/blocks/signatures/var-decls cannot be constructed by an LLM; flag them for the caller to handle
  if ($s | str starts-with "closure") { return {__skip: true} }
  if ($s | str starts-with "block")   { return {__skip: true} }
  if $s in ["vardecl" "variable" "signature" "external-signature"] {
    return {__skip: true}
  }

  {}
}

def snake-case [s: string]: nothing -> string {
  $s | str replace -a '-' '_'
}

# is this a "required positional parameter"?
# note and must stay on the same line as the first half —— starting a line with it makes nu treat it as an external command
def is-required [p: record]: nothing -> bool {
  ((($p | get --optional parameter_type | default "") == "positional") and (not ($p | get --optional is_optional | default false)))
}

# a single parameter → {name, schema, required}.
# a null schema means this parameter must be dropped (an LLM cannot construct it)
# returning null means the entry is not a parameter at all (input/output annotation)
def param->prop [p: record, snake: bool]: nothing -> any {
  let kind = ($p | get --optional parameter_type | default "")
  if $kind == "input" or $kind == "output" { return null }

  let raw = ($p | get --optional parameter_name)
  if $raw == null { return null }
  let name = (if $snake { snake-case $raw } else { $raw })
  let required = (is-required $p)

  if $kind == "switch" {
    let schema = ({type: "boolean"}
      | if ($p | get --optional description) == null { $in } else { upsert description ($p.description) })
    return {name: $name, schema: $schema, required: $required}
  }

  let s = (shape->schema ($p | get --optional syntax_shape))
  if ($s | get --optional __skip | default false) {
    return {name: $name, schema: null, required: $required}
  }

  # carry the default value along, so the LLM is likelier to pass the right argument
  let d = ($p | get --optional parameter_default)
  let schema = (if $d == null { $s } else { $s | upsert default $d })
  let schema = (if ($p | get --optional description) == null { $schema } else { $schema | upsert description ($p.description) })

  {name: $name, schema: $schema, required: $required}
}

# one command record → one tool definition; null means this command is not fit to expose to an LLM
def command->tool [c: record, snake: bool, prefix: any]: nothing -> any {
  let sigs = ($c | get --optional signatures | default {})

  # a command may have several signatures (split by input type); flatten, then dedupe by parameter name
  let params = (
    $sigs
    | values
    | flatten
    | where {|p| ($p | get --optional parameter_name) != null }
    | group-by parameter_name
    | values
    | each {|g| $g | first }
  )

  let info = ($params | each {|p| param->prop $p $snake } | compact)

  # a required positional parameter was dropped → an LLM simply cannot call this command, exclude the whole thing
  if ($info | any {|i| ($i.required) and ($i.schema == null) }) { return null }

  let usable = ($info | where {|i| $i.schema != null })
  let properties = ($usable | reduce --fold {} {|i, acc| $acc | upsert $i.name $i.schema })
  let required = ($usable | where required | get name)

  let input_schema = (
    {type: "object", properties: $properties}
    | if ($required | is-empty) { $in } else { upsert required $required }
  )

  let base = ($c.name | str replace -a ' ' '_')
  let base = (if $snake { snake-case $base } else { $base })
  let name = (if $prefix == null { $base } else { $"($prefix)($base)" })
  let desc = ($c | get --optional description | default "")

  {name: $name, description: $desc, input_schema: $input_schema}
}

# given a list of command names, convert them to a tools array
export def from-commands [
  names: list<string>   # full command name, e.g. ["agent chat"]
  --snake               # convert kebab-case tool and parameter names to snake_case
  --prefix: string      # prefix for tool names
]: nothing -> list {
  let all = (scope commands)

  # validate everything first, then convert: error make must sit at the top level, otherwise
  # each wraps it into "Eval block failed with pipeline input" and the real cause is invisible
  let missing = ($names | where {|n| ($all | where name == $n | is-empty) })
  if ($missing | is-not-empty) {
    let joined = ($missing | str join ', ')
    error make { msg: $"command not found: ($joined). if it comes from a module, use that module first" }
  }

  $names
  | each {|n| command->tool ($all | where name == $n | first) $snake $prefix }
  | compact
}

# given a module name (which must already be `use`d), convert every exported command in it to a tools array
export def from-module [
  module: string        # module name, e.g. "bash"
  --snake
  --prefix: string
]: nothing -> list {
  let found = (scope modules | where name == $module)
  if ($found | is-empty) {
    error make { msg: $"module not found: ($module). use that module first" }
  }

  # a module's commands only give short names; locating them in scope commands by decl_id is the most reliable
  let ids = (($found | first).commands | get decl_id)
  scope commands
  | where {|c| $ids | any {|id| $id == $c.decl_id } }
  | each {|c| command->tool $c $snake $prefix }
  | compact
}
