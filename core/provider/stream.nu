# stream.nu — the streaming state machine, provider-independent (internal)
#
# ── what this is, and what it is not ──
# a provider's `events` command turns one raw SSE line into zero or more
# **normalized events**; this file turns normalized events into the running
# message. the split is the point: the accumulator and the rendering live here
# once, and each dialect only has to describe its own wire format.
#
# the normalized vocabulary:
#   {type: "message_start",  id, model, usage}
#   {type: "block_start",    index, kind: text|thinking|tool_use, id, name}
#   {type: "text_delta",     index, text}
#   {type: "thinking_delta", index, text}
#   {type: "signature_delta",index, sig}
#   {type: "tool_input_delta",index, json}
#   {type: "block_stop",     index}
#   {type: "message_delta",  stop_reason, usage}
#   {type: "message_stop"}
#
# `index` is the position in the assistant's content-block list. a dialect whose
# wire format has no such concept has to synthesize it (see openai.nu).

# the accumulator. it is threaded through transport.stream's reduce, never held
# in a mutable variable — an `each` closure cannot capture one.
export def seed []: nothing -> record {
  {
    blocks: [], idx: -1, stop_reason: null, usage: {}, id: null, model: null
    other: [], mdstate: {buf: "", in_fence: false}
    # per-dialect scratch that must survive across SSE lines. it lives here
    # rather than in the dialect because transport's reduce owns the accumulator,
    # and a closure cannot hold a mutable variable. anthropic ignores it; openai
    # keeps its tool_calls index map in it.
    dialect: {}
  }
}

# replace the nth item of the current block outright.
# avoid variable-indexed cell paths like `update blocks.$i.xxx` — they surprise
# you; rebuilding the list is the most reliable.
export def replace-block [blocks: list, i: int, f: closure]: nothing -> list {
  $blocks | enumerate | each {|r| if $r.index == $i { do $f $r.item } else { $r.item } }
}

# apply one normalized event to the accumulator.
#
# `render` is the markdown line-buffering mode and `show_thinking` the thinking
# echo; both print as a side effect, which is why they are threaded through here
# rather than applied afterwards.
export def apply-event [
  ev: record
  a: record
  show_thinking: bool
  render: bool
  on: bool
  md_step: closure    # (state, chunk, on) -> {state, out}
  md_flush: closure   # (state, on) -> {state, out}
]: nothing -> record {
  let t = ($ev | get --optional type | default "")
  let bi = ($a.idx | default 0)

  if $t == "message_start" {
    return {
      blocks: [], idx: -1, other: $a.other
      dialect: ($a | get --optional dialect | default {})
      mdstate: ($a | get --optional mdstate | default {buf: "", in_fence: false})
      stop_reason: ($ev | get --optional stop_reason)
      usage: ($ev | get --optional usage | default {})
      id: ($ev | get --optional id)
      model: ($ev | get --optional model)
    }
  }

  if $t == "block_start" {
    let kind = ($ev | get --optional kind | default "text")
    let block = (
      if $kind == "tool_use" {
        {type: "tool_use", id: ($ev | get --optional id | default ""), name: ($ev | get --optional name | default ""), input: ""}
      } else if $kind == "thinking" {
        {type: "thinking", thinking: "", signature: ""}
      } else {
        {type: "text", text: ""}
      }
    )
    return ($a | upsert blocks ($a.blocks | append $block) | upsert idx ($ev | get --optional index | default 0))
  }

  if $t == "text_delta" {
    let piece = ($ev | get --optional text | default "")
    if $render {
      # line-buffered rendering: markdown is block-level syntax, so a chunk that
      # isn't finished cannot be rendered (code fences especially); hand it to
      # the markdown module to hold until a newline
      let st = ($a | get --optional mdstate | default {buf: "", in_fence: false})
      let step = (do $md_step $st $piece $on)
      if ($step.out | is-not-empty) { print -n $step.out }
      return (
        $a
        | upsert mdstate $step.state
        | upsert blocks (replace-block $a.blocks $bi {|b| $b | upsert text ($b.text + $piece) })
      )
    }
    print -n $piece
    return ($a | upsert blocks (replace-block $a.blocks $bi {|b| $b | upsert text ($b.text + $piece) }))
  }

  if $t == "thinking_delta" {
    let piece = ($ev | get --optional text | default "")
    if $show_thinking {
      if not ($a | get --optional th_open | default false) {
        print -e ""
        print -e "### thinking"
        print -e ""
      }
      print -e -n $piece
      return ($a | upsert th_open true | upsert blocks (replace-block $a.blocks $bi {|b| $b | upsert thinking ($b.thinking + $piece) }))
    }
    return ($a | upsert blocks (replace-block $a.blocks $bi {|b| $b | upsert thinking ($b.thinking + $piece) }))
  }

  if $t == "signature_delta" {
    let piece = ($ev | get --optional sig | default "")
    return ($a | upsert blocks (replace-block $a.blocks $bi {|b| $b | upsert signature ($b.signature + $piece) }))
  }

  if $t == "tool_input_delta" {
    let piece = ($ev | get --optional json | default "")
    return ($a | upsert blocks (replace-block $a.blocks $bi {|b| $b | upsert input ($b.input + $piece) }))
  }

  if $t == "block_stop" {
    let b = ($a.blocks | get --optional $bi)
    if ($b | get --optional type) == "tool_use" {
      # input is a JSON string assembled piece by piece; only parse it into a
      # record at the end
      let raw = ($b | get --optional input | default "")
      let parsed = (if ($raw | str trim | is-empty) { {} } else { try { $raw | from json } catch { {} } })
      return ($a | upsert blocks (replace-block $a.blocks $bi {|x| $x | upsert input $parsed }))
    }
    return $a
  }

  if $t == "message_stop" {
    # the last line usually has no newline; emit the leftover buffer when wrapping up
    if $render {
      let st = ($a | get --optional mdstate | default {buf: "", in_fence: false})
      let f = (do $md_flush $st $on)
      if ($f.out | is-not-empty) { print -n $f.out }
      return ($a | upsert mdstate $f.state)
    }
    return $a
  }

  if $t == "message_delta" {
    return (
      $a
      | upsert stop_reason ($ev | get --optional stop_reason | default $a.stop_reason)
      | upsert usage ($ev | get --optional usage | default $a.usage)
    )
  }

  # an event we do not model: keep it, so an error can be reported rather than
  # silently swallowed
  ($a | upsert other ($a.other | append ($ev | to json -r)))
}

# fold one raw SSE line into the accumulator: hand it to the dialect, then apply
# whatever normalized events come back.
#
# `events` is (line, state) -> {events, state}. the state is threaded through so
# a dialect whose wire format has no content-block concept can keep the map it
# needs between lines; it rides in the accumulator, which is what survives the
# reduce. anthropic's dialect ignores it entirely.
export def step-line [
  line: string
  a: record
  events: closure      # (line, state) -> {events, state}
  show_thinking: bool
  render: bool
  on: bool
  md_step: closure
  md_flush: closure
]: nothing -> record {
  let res = (do $events $line ($a | get --optional dialect | default {}))
  let carried = ($a | upsert dialect (($res | get --optional state) | default {}))
  (($res | get --optional events) | default [])
  | reduce --fold $carried {|ev, acc| (apply-event $ev $acc $show_thinking $render $on $md_step $md_flush) }
}

# the accumulator → an Anthropic-shaped message body, so a streamed call and a
# non-streamed one hand the caller the same shape and nothing downstream has to
# tell them apart.
export def assemble [a: record]: nothing -> record {
  {
    id: $a.id
    model: $a.model
    role: "assistant"
    content: $a.blocks
    stop_reason: $a.stop_reason
    usage: $a.usage
  }
}
