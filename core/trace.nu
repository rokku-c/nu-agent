# trace.nu — turn an agent trace into a browsable page
#
#   agent "..." --tools ... --json | trace write run.html
#   agent "..." --tools ... --json | trace render | save -f run.html
#
# why a page: a terminal cannot collapse anything, so a long tool result is
# either dumped in full or cut to one line. A page can put each result behind a
# disclosure, so the trace stays skimmable and any result expands on click.
#
# ── why the template is a separate file ──
# HTML/CSS/JS is full of `(` and `'`. Inside nu's $"..." a `(` is parsed as an
# interpolation (rgba(0,0,0,.5) would run the command `0,0,0,.5`), and a nu
# single-quoted string cannot contain a `'` at all. So the page lives in
# tools/trace.html and only the data is injected here — no escaping minefield.

use ./layout.nu

const TEMPLATE = "core/trace.html"

def template-path []: nothing -> path {
  layout root | path join $TEMPLATE
}

def blocks-of-msg [m: record]: nothing -> list {
  let c = ($m | get --optional content)
  if $c == null { return [] }
  let d = ($c | describe)
  if ($d | str starts-with "list") or ($d | str starts-with "table") { $c } else { [] }
}

# block content can be a string or a list of blocks; flatten either to text
def content-text [c: any]: nothing -> string {
  if $c == null { return "" }
  let d = ($c | describe)
  if ($d | str starts-with "list") or ($d | str starts-with "table") {
    $c | each {|b| ($b | get --optional text | default ($b | get --optional content | default "")) } | str join (char nl)
  } else {
    $c | into string
  }
}

# Walk the message list and rebuild the rounds the agent actually ran:
# each assistant turn becomes a round, and the tool_use blocks in it are paired
# with the tool_result blocks in the user message that follows.
export def "build-model" [trace: record]: nothing -> record {
  let msgs = ($trace | get --optional messages | default [])

  mut rounds = []
  # `mut cur = null` would infer the type `nothing`, and assigning a record to it
  # later fails to compile — nu narrows a mutable variable from its initial value.
  # So seed it with a same-shaped record and track presence with a separate flag.
  mut cur = {n: 0, text: "", tools: [], folds: []}
  mut has_cur = false
  mut pending = {}

  for m in $msgs {
    let role = ($m | get --optional role | default "")
    let blocks = (blocks-of-msg $m)

    if $role == "assistant" {
      # a new assistant turn closes the previous round
      if $has_cur { $rounds = ($rounds | append $cur) }
      let text = ($blocks | where {|b| ($b | get --optional type) == "text" } | get --optional text | default [] | str join (char nl))
      let uses = ($blocks | where {|b| ($b | get --optional type) == "tool_use" })
      for u in $uses {
        $pending = ($pending | upsert ($u | get --optional id | default "") {
          name: ($u | get --optional name | default "?"),
          input: ($u | get --optional input | default {})
        })
      }
      $cur = {n: (($rounds | length) + 1), text: $text, tools: [], folds: []}
      $has_cur = true
    } else if $role == "user" and $has_cur {
      let results = ($blocks | where {|b| ($b | get --optional type) == "tool_result" })
      for r in $results {
        let id = ($r | get --optional tool_use_id | default "")
        let info = ($pending | get --optional $id)
        let entry = {
          name: ($info | get --optional name | default "?"),
          input: ($info | get --optional input | default {}),
          result: (content-text ($r | get --optional content)),
          is_error: ($r | get --optional is_error | default false)
        }
        $cur = ($cur | upsert tools ($cur.tools | append $entry))
      }
    }
  }
  if $has_cur { $rounds = ($rounds | append $cur) }

  # attach fold records to the round they happened before
  for f in ($trace | get --optional folds | default []) {
    let rn = ($f | get --optional round | default 0)
    $rounds = ($rounds | each {|r|
        if $r.n == $rn { $r | upsert folds ($r.folds | append $f) } else { $r }
      })
  }

  # the first user message is the task
  let first_user = ($msgs | where {|m| ($m | get --optional role) == "user" } | first)
  let task = (if $first_user == null { "" } else { content-text ($first_user | get --optional content) })

  let tools = ($rounds | each {|r| $r.tools } | flatten)

  {
    title: "Agent Trace"
    task: $task
    stats: {
      rounds: ($trace | get --optional rounds | default ($rounds | length))
      tool_calls: ($trace | get --optional tool_calls | default ($tools | length))
      last_input_tokens: ($trace | get --optional last_input_tokens | default "")
      stop_reason: ($trace | get --optional stop_reason | default "")
    }
    rounds: $rounds
  }
}

# render the trace into a self-contained HTML page
export def render []: record -> string {
  let trace = $in
  let tpl_path = (template-path)
  if not ($tpl_path | path exists) {
    error make { msg: $"template not found: ($tpl_path)" }
  }

  let model = (build-model $trace)
  # base64 rather than JSON with `<` escaped. The usual trick is replacing `<`
  # with the JSON escape < (so a tool result containing </script> cannot
  # break out of the data block), but that literal is itself an escape sequence
  # in every JSON-encoded tool call that would have to carry it — it kept being
  # silently decoded into a bare `<`. base64 has no such character.
  let data = ($model | to json -r | encode base64)

  open --raw $tpl_path | str replace -a "/*__TRACE_DATA__*/" $data
}

# render and write to a file, returning the path.
#
# named `write`, not `save` — `save` is a builtin, and a same-named export in a
# module shadows it, so the `save -f` inside this very function resolved back to
# itself and failed with "the save command doesn't have flag -f".
export def write [path: path]: record -> path {
  let trace = $in
  let html = (render-from $trace)
  $html | save -f $path
  $path | path expand
}

def render-from [trace: record]: nothing -> string {
  $trace | render
}
