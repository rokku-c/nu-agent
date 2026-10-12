# markdown.nu — render markdown in terminal style
#
#   "## heading\n**bold** and `code`" | markdown render
#   agent chat "explain X" | markdown render
#   markdown render --plain          # force plain text (strip markers, no colour)
#
# ── built on nu's own from md ──
# `from md --verbose` gives a complete markdown AST (type / attrs / children),
# so this just walks the AST and colours by node type — no hand-written parser.
#
# ── division of labour with style ──
# the colour switch is delegated to style: output into a pipe degrades to plain text,
# so agent tool results and anything written to files carry no colour codes.
#
# ── one gotcha ──
# nu's `ansi` accepts **colour** codes (green / red / green_bold …) but not
# **attribute** codes (underline / italic / bold …); attributes must be built
# by hand as raw escapes:   (char -i 27) + "[3m"   →  italic
# observed: ansi underline errors out outright.

use ./style.nu

def esc [c: string, on: bool]: nothing -> string {
  if $on { $"(char -i 27)[($c)m" } else { "" }
}

def wrap [text: string, color: string, on: bool]: nothing -> string {
  if $on { $"(ansi $color)($text)(ansi reset)" } else { $text }
}

# collected table rows → nu table (first row becomes the header)
export def "rows-to-table" [rows: list]: nothing -> any {
  if ($rows | is-empty) { return null }
  let header = ($rows | first)
  let names = ($header | enumerate | each {|r|
      let n = ($r.item | into string | str trim)
      if ($n | is-empty) { $"col($r.index + 1)" } else { $n }
    })
  let body = (if ($rows | length) > 1 { $rows | skip 1 } else { [] })
  $body | each {|cells|
    $names | enumerate | reduce --fold {} {|c, acc|
      $acc | upsert $c.item ($cells | get --optional $c.index | default "" | into string)
    }
  }
}

# markdown table text lines → list of cell lists (drops the --- separator rows)
def md-table-rows [lines: list<string>]: nothing -> list {
  let cells_of = {|l| $l | str trim | str trim -c "|" | split row "|" | each {|c| $c | str trim } }
  let is_sep = {|l|
    let cs = (do $cells_of $l)
    ($cs | is-not-empty) and ($cs | all {|c| $c =~ '^:?-{2,}:?$' })
  }
  $lines | where {|l| not (do $is_sep $l) } | each {|l| (do $cells_of $l) }
}

# render the buffered table lines as one block. under two lines is not a table, pass it through.
def flush-tbl [lines: list<string>, on: bool]: nothing -> list<string> {
  if ($lines | is-empty) { return [] }
  if ($lines | length) < 2 {
    return ($lines | each {|l| (render-line $l $on) })
  }
  let rows = (md-table-rows $lines)
  let tbl = (rows-to-table $rows)
  if ($tbl == null) { return ($lines | each {|l| (render-line $l $on) }) }
  [($tbl | table)]
}

# render one AST node, recursively
def render-node [n: record, on: bool]: nothing -> string {
  let t = ($n | get --optional type | default "text")
  let a = ($n | get --optional attrs | default {})
  let kids = ($n | get --optional children | default [])
  let inner = ($kids | each {|c| render-node $c $on } | str join "")

  # headings
  if ($t =~ '^h[1-6]$') {
    let lvl = ($t | str substring 1.. | into int)
    let color = (if $lvl <= 2 { "green_bold" } else { "cyan" })
    let body = (wrap $inner $color $on)
    let bar = (esc "4" $on)
    let rule = (wrap ($"─" | fill -w 40) "dark_gray" $on)
    return (
      if $lvl == 1 { $"($bar)($body)(esc 24 $on)\n($rule)\n" }
      else if $lvl == 2 { $"($bar)($body)(esc 24 $on)\n" }
      else { $"($body)\n" }
    )
  }

  if $t == "strong" { return $"((esc 1 $on))($inner)(esc 22 $on)" }
  if $t == "emphasis" { return $"((esc 3 $on))($inner)(esc 23 $on)" }
  if $t == "delete" { return $"((esc 9 $on))($inner)(esc 29 $on)" }
  # inline code keeps its content in attrs.value (same as fenced blocks), not in children —
  # reading only children would drop the content entirely
  if $t == "code_inline" {
    return (wrap ($a | get --optional value | default $inner) "cyan" $on)
  }

  if $t == "link" {
    let url = ($a | get --optional url | default "")
    if $on { return $"($inner) (esc 2 $on)($url)(esc 22 $on)" }
    return $"($inner) <($url)>"
  }

  if $t == "image" {
    let url = ($a | get --optional url | default "")
    return (wrap $"[image] ($url)" "dark_gray" $on)
  }

  # code block: the value is in attrs, there are no children
  if $t == "code" {
    if ($a | get --optional fence | default false) {
      let lang = ($a | get --optional lang | default "")
      let val = ($a | get --optional value | default "")
      let tag = (wrap $"─ ($lang) " "dark_gray" $on)
      let body = ($val | lines | each {|l| wrap $"  ($l)" "dark_gray" $on } | str join (char nl))
      return $"($tag)\n($body)\n"
    }
    # indented code block
    let val = ($a | get --optional value | default $inner)
    return ($val | lines | each {|l| wrap $"  ($l)" "dark_gray" $on } | str join (char nl))
  }

  # list item: attrs carry level / index / ordered
  if $t == "list" {
    let lvl = ($a | get --optional level | default 0)
    let idx = ($a | get --optional index | default 0)
    let ordered = ($a | get --optional ordered | default false)
    let bullet = (if $ordered { $"($idx + 1)." } else { "•" })
    let pad = ("  " | fill -w (($lvl + 1) * 2))
    return $"($pad)(wrap $bullet 'cyan' $on) ($inner)"
  }

  if $t == "blockquote" {
    return ($inner | lines | each {|l| $"(wrap '│' 'dark_gray' $on) ($l)" } | str join (char nl))
  }

  if $t in ["Horizontal_rule" "rule" "hrule"] {
    return (wrap ("─" | fill -w 40) "dark_gray" $on)
  }

  if $t in ["footnote" "footnoteref"] { return $inner }
  # table: hand the whole thing to nu's table renderer; its shape follows $env.config.table.mode
  if $t == "nutable" {
    let tbl = (rows-to-table ($a | get --optional rows | default []))
    if $tbl == null { return "" }
    return ($tbl | table)
  }
  if $t == "text" { return ($a | get --optional value | default $inner) }
  if $t == "table_cell" { return $inner }
  if $t == "table_align" { return "" }

  # unknown type: emit children, never swallow the content
  $inner
}

# ── streaming render ──
#
# markdown is block-level syntax: an unfinished piece cannot be rendered (code fences most of all). so
# streaming advances **line by line** — a line goes out only when its newline arrives, the leftover half
# stays buffered. the cost is output lagging the raw stream by one line, imperceptible to the eye.
#
# state is held by the caller and passed back in (pure function + explicit state), so that reduce
# accumulator in agent.nu can carry it directly, with no mutable variables to manage.

export def "stream-start" []: nothing -> record {
  {buf: "", in_fence: false, tbl: [], last_blank: false}
}

# render a single line: reuse the whole-document AST path rather than a second parser
def render-line [line: string, on: bool]: nothing -> string {
  if ($line | str trim | is-empty) { return "" }
  let ast = (try { $line | from md --verbose } catch { return $line })
  $ast | each {|n| render-node $n $on } | str join ""
}

# feed a new chunk, return {state, out}. out is what should be displayed now (may be empty)
export def "stream-step" [
  state: record
  chunk: string
  on: bool
]: nothing -> record {
  let buffered = ($state.buf + $chunk)
  let parts = ($buffered | split row (char nl))

  # no newline seen yet → keep buffering
  if ($parts | length) <= 1 {
    return {state: ($state | upsert buf $buffered), out: ""}
  }

  let complete = ($parts | first (($parts | length) - 1))
  let rest = ($parts | last)

  let r = ($complete | reduce --fold {fence: $state.in_fence, tbl: ($state | get --optional tbl | default []), new: [], last_blank: ($state | get --optional last_blank | default false)} {|l, acc|
      let is_fence = ($l | str trim | str starts-with '```')
      let is_tbl = ($l | str trim | str starts-with '|')

      if $acc.fence or $is_fence {
        # neither the fence line nor its interior is parsed: flush the buffered table, then dim the whole line
        {
          fence: (if $is_fence { not $acc.fence } else { $acc.fence })
          tbl: []
          new: ($acc.new | append (flush-tbl $acc.tbl $on) | append (wrap $l "dark_gray" $on))
          last_blank: false
        }
      } else if $is_tbl {
        # buffer table rows — a lone | a | b | is not a table; the whole block has to arrive first
        {fence: false, tbl: ($acc.tbl | append $l), new: $acc.new, last_blank: false}
      } else {
        let pre = (flush-tbl $acc.tbl $on)
        let rendered = (render-line $l $on)
        let is_blank = (($rendered | str trim) | is-empty)
        # Collapse runs of blank lines, which is what render does at the end of
        # the whole-document path. Streaming has no such pass — it emits line by
        # line — so a model that pads its output would otherwise get every blank.
        if ($is_blank and $acc.last_blank and ($pre | is-empty)) {
          {fence: false, tbl: [], new: $acc.new, last_blank: true}
        } else {
          {
            fence: false
            tbl: []
            new: ($acc.new | append $pre | append $rendered)
            last_blank: (if ($pre | is-empty) { $is_blank } else { false })
          }
        }
      }
    })

  {
    state: ($state | upsert buf $rest | upsert in_fence $r.fence | upsert tbl $r.tbl | upsert last_blank $r.last_blank)
    # Only what THIS call produced. Returning the accumulated lines was the bug:
    # the caller does `print -n $out` per chunk, so every newline re-printed the
    # whole history — which is what made a padded answer look like a wall of
    # blank lines. My unit test missed it because it only printed a trimmed
    # summary of each result.
    out: (if ($r.new | is-empty) { "" } else { ($r.new | str join (char nl)) + (char nl) })
  }
}

# flush the leftover line when the stream ends (the last line usually has no newline)
export def "stream-flush" [state: record, on: bool]: nothing -> record {
  if ($state.buf | is-empty) { return {state: $state, out: ""} }
  # flush the buffered table first, then handle the leftover line
  let pre = (flush-tbl ($state | get --optional tbl | default []) $on)
  let rendered = (
    if $state.in_fence { wrap $state.buf "dark_gray" $on } else { render-line $state.buf $on }
  )
  let all = ($pre | append $rendered | where {|x| $x | is-not-empty })
  {state: ($state | upsert buf "" | upsert tbl []), out: (if ($all | is-empty) { "" } else { ($all | str join (char nl)) + (char nl) })}
}

# collapse the flat table nodes into **one whole** table.
#
# tables are **flat** in the AST: table_cell(row=0,col=0..2) → table_align →
# table_cell(row=1,col=0..2) … . handing that to the main renderer breaks twice:
#   · table_align counts as an inline node, and its source line number moved → starts a blank line
#   · the separator row carries no content of its own and is silently dropped
# so rows are gathered first and the whole table goes to nu's table renderer —
# its shape follows $env.config.table.mode: rounded box in a terminal, markdown in a pipe/tool.
def collapse-tables [ast: list, on: bool]: nothing -> list {
  mut out = []
  mut trows = []      # rows collected for the current table; each row is a list of cells
  mut cur = []
  mut currow = -1

  for n in $ast {
    let t = ($n | get --optional type | default "")

    if $t == "table_cell" {
      let r = ($n | get --optional attrs | get --optional row | default 0)
      if $r != $currow and ($cur | is-not-empty) {
        $trows = ($trows | append [$cur])
        $cur = []
      }
      $currow = $r
      $cur = ($cur | append (render-node $n $on))
    } else if $t == "table_align" {
      if ($cur | is-not-empty) {
        $trows = ($trows | append [$cur])
        $cur = []
      }
      $currow = -1
    } else {
      # non-table node → the current table ends, flush it
      if ($cur | is-not-empty) {
        $trows = ($trows | append [$cur])
        $cur = []
      }
      if ($trows | is-not-empty) {
        $out = ($out | append {type: "nutable", attrs: {rows: $trows}, children: []})
        $trows = []
      }
      $currow = -1
      $out = ($out | append $n)
    }
  }

  if ($cur | is-not-empty) { $trows = ($trows | append [$cur]) }
  if ($trows | is-not-empty) {
    $out = ($out | append {type: "nutable", attrs: {rows: $trows}, children: []})
  }
  $out
}

# render markdown into text fit for terminal display
export def render [
  --plain    # force plain text (strip markers, no colour)
  --force    # force rendering, bypassing the "is stdout a terminal" test
]: any -> string {
  # tolerate null/empty: agent --stream returns null (the text is already printed out),
  # and piping that straight into markdown render raises only_supports_this_input_type, an error that
  # explains nothing. but do not silently return empty either — that is just new confusion; hint instead.
  if ($in | describe) == "nothing" {
    print -e "⚠ markdown render got an empty value. streaming commands (agent --stream) return null; the text is already printed;"
    print -e "  to render streaming output add --md (e.g. agent --stream --md \"...\") instead of piping into it."
    return ""
  }
  let md = ($in | default "" | into string)
  if ($md | str trim | is-empty) { return "" }

  let on = (if $plain { false } else if $force { true } else { style enabled })

  let ast = (try { $md | from md --verbose } catch { null })
  if $ast == null { return $md }   # return as-is when parsing fails; never lose the content

  # collapse tables into whole-row blocks first, otherwise the flat table_cell/table_align get mangled by inline logic
  let ast = (collapse-tables $ast $on)

  # the AST top level is **flat**: text / strong / emphasis inside a paragraph are
  # siblings, with no paragraph wrapper. so inline and block must be told apart —
  # inline nodes append to the current line, only block nodes start a new line.
  let inline_types = ["text" "strong" "emphasis" "delete" "code_inline" "link" "footnoteref" "table_align"]

  let rendered = ($ast | reduce --fold {lines: [], prev_row: -1, prev_line: -1} {|n, acc|
      let t = ($n | get --optional type | default "")
      let ln = ($n | get --optional position | get --optional start | get --optional line | default 0)

      # table cell: the same row (equal attrs.row) joins the same line
      if $t == "table_cell" {
        let row = ($n | get --optional attrs | get --optional row | default 0)
        let body = (render-node $n $on)
        let piece = $"| ($body) "
        if $row != $acc.prev_row {
          {lines: ($acc.lines | append $piece), prev_row: $row, prev_line: $ln}
        } else {
          {
            lines: (
              $acc.lines | if ($acc.lines | is-empty) { append $piece } else {
                update (($acc.lines | length) - 1) {|l| $l + $piece }
              }
            )
            prev_row: $row
            prev_line: $ln
          }
        }
      } else if $t in $inline_types {
        let s = (render-node $n $on)
        # inline nodes need the source line number too: a flat AST records no
        # "newline", and without position the text after ![img](u) sticks to the image
        let newline = ($ln > $acc.prev_line) or ($acc.lines | is-empty)
        {
          lines: (
            $acc.lines | if $newline { append $s } else {
              update (($acc.lines | length) - 1) {|l| $l + $s }
            }
          )
          prev_row: $acc.prev_row
          prev_line: $ln
        }
      } else {
        {lines: ($acc.lines | append (render-node $n $on)), prev_row: -1, prev_line: $ln}
      }
    })

  # wrap up: squeeze out runs of blank lines so paragraphs sit one blank line apart
  $rendered.lines
  | str join (char nl)
  | str replace -r -a '\n{3,}' (char nl + char nl)
  | str trim -r -c (char nl)
}
