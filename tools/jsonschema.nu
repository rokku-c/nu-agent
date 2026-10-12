# jsonschema.nu — infer JSON Schema from sample data
#
# purpose: turn real data into JSON Schema, to hand to an LLM to constrain structured output
# (Anthropic's output_format / OpenAI's response_format).
#
#   use jsonschema.nu
#
#   # infer: describes "the value you hand it" itself
#   {id: 1, name: "x"} | jsonschema infer                    # → object
#   [[id name]; [1 a] [2 b]] | jsonschema infer              # → array of object
#   open data.json | jsonschema infer --title "user"
#
#   # from-samples: give a batch of samples, merge them into the schema for a "single" item (no array wrapper)
#   jsonschema from-samples [{a: 1, b: 2} {a: 3}]
#   open rows.json | jsonschema from-samples --strict
#
# note: the command is `jsonschema ...`, not `schema ...` —— nushell ships a built-in
# `schema` command (which inspects a SQLite database), and calling it schema gets intercepted by it.
#
# inference is conservative: keys that never appear in the samples do not enter properties,
# and keys that appear in only some samples do not enter required.

# take a schema's type field, normalised to a list so unions are easy
def types-of [s: record]: nothing -> list<string> {
  let t = ($s | get --optional type | default "any")
  if ($t | describe) == "string" { [$t] } else { $t }
}

def is-object [s: record]: nothing -> bool {
  (types-of $s) | any {|t| $t == "object" }
}

# merge several schemas into one schema that accepts all of them
def merge [schemas: list]: nothing -> record {
  if ($schemas | is-empty) { return {} }
  # if any one of them is a completely unknown empty schema, nothing is constrained ——
  # otherwise "unknown" would masquerade as type:"any" and wash out the other constraints
  if ($schemas | any {|s| ($s | is-empty) }) { return {} }

  let all = ($schemas | each {|s| types-of $s } | flatten | uniq | sort)
  let not_null = ($all | where $it != "null")

  if ($not_null | is-empty) { return {type: "null"} }
  # several non-null types: take the plain type union, do not merge structure further down
  if ($not_null | length) > 1 { return {type: $all} }

  let kind = $not_null.0
  let nn = ($schemas | where {|s| (types-of $s) | any {|t| $t != "null"} })

  let core = (
    if $kind == "object" {
      let props = ($nn | each {|s| $s | get --optional properties | default {} })
      let keys = ($props | each {|p| $p | columns } | flatten | uniq | sort)
      let merged = ($keys | reduce --fold {} {|k, acc|
        let vals = ($props | each {|p| $p | get --optional $k } | compact)
        $acc | insert $k (merge $vals)
      })
      let req = ($keys | where {|k| $props | all {|p| ($p | columns) | any {|c| $c == $k } } })
      {type: "object", properties: $merged} | if ($req | is-empty) { $in } else { insert required $req }
    } else if $kind == "array" {
      let items = ($nn | each {|s| $s | get --optional items | default {} })
      {type: "array", items: (merge $items)}
    } else {
      {type: $kind}
    }
  )

  # if null is present, union it into the type rather than dropping the structure already inferred
  if ($all | any {|t| $t == "null" }) {
    $core | upsert type ((types-of $core) | append "null" | uniq | sort)
  } else {
    $core
  }
}

# a single nu value → schema
#
# note describe's output is parameterised: "record<a: int>" / "table<a: int>" /
# "list<oneof<int, string>>", but an empty record is the bare "record".
# so here, apart from scalars, everything is matched by prefix
def of-value [v: any]: nothing -> record {
  let d = ($v | describe)

  if $d == "nothing"  { return {type: "null"} }
  if $d == "bool"     { return {type: "boolean"} }
  if $d == "int"      { return {type: "integer"} }
  if $d == "float"    { return {type: "number"} }
  if $d == "string"   { return {type: "string"} }
  if $d == "datetime" { return {type: "string", format: "date-time"} }
  if $d == "binary"   { return {type: "string", contentEncoding: "base64"} }
  if $d == "duration" { return {type: "integer", description: "nanoseconds (1 second = 1000000000)"} }
  if $d == "filesize" { return {type: "integer", description: "bytes"} }
  if $d == "range"    { return {type: "array", items: {type: "integer"}} }
  if $d == "cell-path" { return {type: "string", description: "nu cell path"} }

  if ($d | str starts-with "list") or ($d | str starts-with "table") {
    return {type: "array", items: (merge ($v | each {|x| of-value $x }))}
  }

  if ($d | str starts-with "record") {
    let keys = ($v | columns)
    if ($keys | is-empty) { return {type: "object", properties: {}} }
    let props = ($keys | reduce --fold {} {|k, acc|
      $acc | insert $k (of-value ($v | get $k))
    })
    return {type: "object", properties: $props, required: $keys}
  }

  if ($d | str starts-with "closure") or ($d | str starts-with "block") {
    return {type: "string", description: "nu closure, not serializable"}
  }

  # unknown type (any / custom …): leave it unconstrained, let the caller decide
  {}
}

# wrap the inferred schema in the $schema / title / strict shell
def decorate [
  base: record
  title: any
  draft: string
  strict: bool
  no_schema_key: bool
]: nothing -> record {
  # strict marks every key that appears as required —— that is what OpenAI's strict mode demands
  let req = (if $strict and (is-object $base) { $base | get --optional properties | default {} | columns } else { [] })

  # always upsert: of-value may already have built a required column, and insert would raise column_already_exists
  $base
  | if ($req | is-empty) { $in } else { upsert required $req }
  | if ($strict and (is-object $base)) { upsert additionalProperties false } else { $in }
  | if $title == null { $in } else { upsert title $title }
  | if $no_schema_key { $in } else { upsert '$schema' $"https://json-schema.org/draft/($draft)/schema" }
}

# infer the JSON Schema of "the value you hand it". give it a list/table and you get an array schema
export def infer [
  --title: string              # top-level title
  --draft: string = "2020-12"  # draft version of $schema
  --strict                     # OpenAI strict mode: all keys required + additionalProperties=false
  --no-schema-key              # do not emit the $schema field (some APIs reject it)
]: any -> record {
  let data = $in
  decorate (of-value $data) $title $draft $strict $no_schema_key
}

# given a batch of samples, merge them into the schema for a single item (no array wrapper)
export def from-samples [
  --title: string
  --draft: string = "2020-12"
  --strict
  --no-schema-key
]: list -> record {
  let samples = $in
  let base = (merge ($samples | each {|x| of-value $x }))
  decorate $base $title $draft $strict $no_schema_key
}
