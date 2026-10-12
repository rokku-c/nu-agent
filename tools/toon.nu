# toon.nu — encode data as TOON (Token-Oriented Object Notation)
#
#   use toon.nu
#   [[a b]; [1 2]] | toon encode
#
# TOON is a line-oriented, indentation-based encoding of the JSON data model,
# aimed at LLM input: typically 30-60% fewer tokens than JSON for uniform arrays
# of objects. Upstream: https://github.com/toon-format/toon
#
# ── why an alias, not `to toon` in this file ──
# nu's `to` is a builtin command family, and user code cannot join it:
#   export def "to toon" ...      → "extra positional argument" (the builtin `to` wins)
#   export alias "to toon" = ...  → same failure when exported from a module
# but a PLAIN alias at the top level of config.nu does work. So this module
# provides the command and config.nu carries:
#   alias "to toon" = toon encode
#
# (Writing a Rust plugin is the only way to register `to toon` properly — the
# plugin protocol can extend the family. There is no Rust toolchain on this
# machine, so that route is out for now.)
#
# ── scope ──
# Encoder only. The exact quoting rule could not be read from the spec (both
# github.com and cdn.jsdelivr.net are unreachable here), so this quotes
# conservatively — whenever a string could be misread. Over-quoting is always
# valid TOON and never ambiguous; it just costs a few tokens.

const INDENT = "  "

# a string that could be misread bare: empty, structurally significant
# characters, surrounding whitespace, or a literal that parses as another type
def needs-quote [s: string]: nothing -> bool {
  if ($s | is-empty) { return true }
  if ($s | str contains '"') { return true }
  if ($s =~ '[,\[\]{}:|\t\n\r]') { return true }
  if ($s != ($s | str trim)) { return true }
  if ($s in ["true" "false" "null"]) { return true }
  # a numeric literal, so "1" is not read back as the number 1
  if ($s =~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$') { return true }
  false
}

def quote-str [s: string]: nothing -> string {
  let esc = ($s | str replace -a '\' '\\' | str replace -a '"' '\"')
  $"\"($esc)\""
}

# one scalar → its TOON text
def scalar [v: any]: nothing -> string {
  let d = ($v | describe)
  if $d == "nothing" { return "null" }
  if $d == "bool" { return ($v | into string) }
  if $d == "int" { return ($v | into string) }
  if $d == "float" { return ($v | into string) }
  if $d == "datetime" { return ((($v | into string)) | if (needs-quote $in) { quote-str $in } else { $in }) }
  let s = ($v | into string)
  if (needs-quote $s) { quote-str $s } else { $s }
}

# is this a leaf (not a record or list)?
def is-scalar [v: any]: nothing -> bool {
  let d = ($v | describe)
  not (($d | str starts-with "record") or ($d | str starts-with "list") or ($d | str starts-with "table"))
}

# if every row is a record with the same key set, return that key list, else null
def uniform-keys [rows: list]: nothing -> any {
  if ($rows | is-empty) { return null }
  let kinds = ($rows | each {|r| $r | describe } | uniq)
  if ($kinds | length) != 1 { return null }
  if not (($kinds | first) | str starts-with "record") { return null }
  let first_keys = (($rows | first) | columns)
  let same = ($rows | all {|r| (($r | columns) | sort) == ($first_keys | sort) })
  if $same { $first_keys } else { null }
}

# A column whose every value is a uniform record folds into the header as a
# nested field group: temp{min,max}. Returns null when it does not apply.
def nested-group [rows: list, key: string]: nothing -> any {
  let vals = ($rows | each {|r| $r | get --optional $key | default null })
  if ($vals | any {|v| (is-scalar $v) }) { return null }
  uniform-keys $vals
}

# render a value into lines. `label` is the header text ("key", "key[3]",
# or null for a bare array element).
def emit [v: any, label: any, depth: int]: nothing -> list<string> {
  # built by repetition, not `"  " | fill -w ($depth*2)`: fill only pads, it never
  # truncates, so at depth 0 it handed back the original two spaces and every
  # line came out indented one level too deep.
  let pad = (0..<$depth | each { $INDENT } | str join "")
  let head = (if $label == null { "" } else { $label })

  if (is-scalar $v) {
    return [$"($pad)($head): (scalar $v)"]
  }

  let d = ($v | describe)
  if ($d | str starts-with "record") {
    let keys = ($v | columns)
    if ($keys | is-empty) {
      return (if $head == "" { [$"($pad){}"] } else { [$"($pad)($head): {}"] })
    }
    # No label means "top level, or a bare array element": there is no header
    # line to nest under, so the keys go at THIS depth. Emitting `{}` here was
    # the bug — the top-level call passes no label too, so every record at the
    # root collapsed to `{}`.
    if $head == "" {
      return ($keys | each {|k| emit ($v | get $k) $k $depth } | flatten)
    }
    let inner = ($keys | each {|k| emit ($v | get $k) $k ($depth + 1) } | flatten)
    return ([$"($pad)($head):"] | append $inner)
  }

  # list
  let n = ($v | length)
  if $n == 0 { return [$"($pad)($head)[0]:"] }

  # inline: every element a scalar
  if ($v | all {|x| is-scalar $x }) {
    let cells = ($v | each {|x| scalar $x } | str join ",")
    return [$"($pad)($head)[($n)]: ($cells)"]
  }

  # tabular: uniform records
  let keys = (uniform-keys $v)
  if $keys != null {
    let cols = ($keys | each {|k|
        let g = (nested-group $v $k)
        if $g == null { $k } else { $"($k){($g | str join ",")}" }
      })
    let rows = ($v | each {|r|
        let cells = ($keys | each {|k|
            let val = ($r | get --optional $k | default null)
            let g = (nested-group $v $k)
            if $g == null {
              scalar $val
            } else {
              ($g | each {|gk| scalar ($val | get --optional $gk | default null) } | str join ",")
            }
          } | str join ",")
        $"($pad)($INDENT)($cells)"
      })
    return ([$"($pad)($head)[($n)]{($cols | str join ',')}:" ] | append $rows)
  }

  # list form
  let items = ($v | each {|x|
      if (is-scalar $x) {
        [$"($pad)($INDENT)- (scalar $x)"]
      } else if (($x | describe) | str starts-with "record") {
        let ks = ($x | columns)
        if ($ks | is-empty) {
          [$"($pad)($INDENT)- {}"]
        } else {
          let first = ($ks | first)
          let head_line = [$"($pad)($INDENT)- ($first): (scalar ($x | get $first))"]
          let rest = (($ks | skip 1) | each {|k| emit ($x | get $k) $k ($depth + 2) } | flatten)
          $head_line | append $rest
        }
      } else {
        [$"($pad)($INDENT)-"] | append (emit $x null ($depth + 2))
      }
    } | flatten)
  return ([$"($pad)($head)[($n)]:"] | append $items)
}

# Encode a value as TOON.
#
#   [[id name]; [1 Alice]] | toon encode
export def encode []: any -> string {
  let v = $in
  # no trailing newline and no trailing spaces, per the format's invariants
  (emit $v null 0 | each {|l| $l | str trim -r } | str join (char nl))
}
