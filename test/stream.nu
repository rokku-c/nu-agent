#!/usr/bin/env nu
# stream.nu — the SSE state machine, replayed from canned bytes
#
# hermetic on purpose. the e2e suite covers streaming too, but only against a
# live endpoint, which cannot exercise the shapes that matter here: interleaved
# thinking and signature deltas, a tool_use input assembled from JSON fragments,
# a gateway that answers an error as plain JSON instead of SSE.
#
# the modules are used directly rather than through `agent`, so a failure points
# at the state machine instead of at the HTTP call above it.

use ./harness.nu *
use ./../core/provider/stream.nu
use ./../core/provider/anthropic.nu

# no-op renderer: this suite is about assembly, not display
let no_md = {|st, c, o| {state: $st, out: ""}}
let no_flush = {|st, o| {state: $st, out: ""}}

# feed raw SSE lines through the dialect and the state machine
def replay [lines: list<string>]: nothing -> record {
  $lines | reduce --fold (stream seed) {|l, acc|
    stream step-line $l $acc {|line| anthropic events $line } false true false $no_md $no_flush
  }
}

# build a data line from a JSON-ready record
def sse [ev: record]: nothing -> string {
  $"data: ($ev | to json -r)"
}

let text_turn = [
  "event: message_start"
  (sse {type: "message_start", message: {id: "msg_1", model: "m", stop_reason: null, usage: {input_tokens: 10, output_tokens: 1}}})
  (sse {type: "content_block_start", index: 0, content_block: {type: "text", text: ""}})
  (sse {type: "content_block_delta", index: 0, delta: {type: "text_delta", text: "Hel"}})
  (sse {type: "content_block_delta", index: 0, delta: {type: "text_delta", text: "lo"}})
  (sse {type: "content_block_stop", index: 0})
  (sse {type: "message_delta", delta: {stop_reason: "end_turn"}, usage: {output_tokens: 7}})
  (sse {type: "message_stop"})
]

let tool_turn = [
  (sse {type: "message_start", message: {id: "msg_2", model: "m", usage: {input_tokens: 10, output_tokens: 1}}})
  (sse {type: "content_block_start", index: 0, content_block: {type: "thinking", thinking: ""}})
  (sse {type: "content_block_delta", index: 0, delta: {type: "thinking_delta", thinking: "let me "}})
  (sse {type: "content_block_delta", index: 0, delta: {type: "thinking_delta", thinking: "think"}})
  (sse {type: "content_block_delta", index: 0, delta: {type: "signature_delta", signature: "sig-abc"}})
  (sse {type: "content_block_stop", index: 0})
  (sse {type: "content_block_start", index: 1, content_block: {type: "text", text: ""}})
  (sse {type: "content_block_delta", index: 1, delta: {type: "text_delta", text: "working"}})
  (sse {type: "content_block_stop", index: 1})
  (sse {type: "content_block_start", index: 2, content_block: {type: "tool_use", id: "t1", name: "calc", input: {}}})
  (sse {type: "content_block_delta", index: 2, delta: {type: "input_json_delta", partial_json: "{\"expr\":"}})
  (sse {type: "content_block_delta", index: 2, delta: {type: "input_json_delta", partial_json: " \"1+1\"}"}})
  (sse {type: "content_block_stop", index: 2})
  (sse {type: "message_delta", delta: {stop_reason: "tool_use"}, usage: {output_tokens: 20}})
  (sse {type: "message_stop"})
]

let results = [
  (case "stream: a plain text turn assembles into one text block" {
    let m = (stream assemble (replay $text_turn))
    (eq "stream: a plain text turn assembles into one text block" $m.content [{type: "text", text: "Hello"}])
  })

  (case "stream: the assembled shape matches a non-streamed response" {
    # this is the contract that lets the loop ignore which path ran
    let m = (stream assemble (replay $text_turn))
    (eq "stream: the assembled shape matches a non-streamed response" ($m | columns | sort) ["content" "id" "model" "role" "stop_reason" "usage"])
  })

  (case "stream: stop_reason arrives on message_delta, not message_start" {
    let m = (stream assemble (replay $text_turn))
    (eq "stream: stop_reason arrives on message_delta, not message_start" $m.stop_reason "end_turn")
  })

  (case "stream: usage from message_delta replaces the start-time usage" {
    let m = (stream assemble (replay $text_turn))
    (eq "stream: usage from message_delta replaces the start-time usage" $m.usage.output_tokens 7)
  })

  (case "stream: thinking deltas accumulate and keep their signature" {
    let m = (stream assemble (replay $tool_turn))
    let th = ($m.content | where type == "thinking" | first)
    (eq "stream: thinking deltas accumulate and keep their signature" [$th.thinking $th.signature] ["let me think" "sig-abc"])
  })

  (case "stream: a tool_use input is reassembled from JSON fragments and parsed" {
    # the fragments are not valid JSON individually — only the end of the block
    # may parse them
    let m = (stream assemble (replay $tool_turn))
    let t = ($m.content | where type == "tool_use" | first)
    (eq "stream: a tool_use input is reassembled from JSON fragments and parsed" [$t.id $t.name $t.input] ["t1" "calc" {expr: "1+1"}])
  })

  (case "stream: blocks keep the order the server opened them in" {
    let m = (stream assemble (replay $tool_turn))
    (eq "stream: blocks keep the order the server opened them in" ($m.content | get type) ["thinking" "text" "tool_use"])
  })

  (case "stream: a tool_use turn reports stop_reason tool_use" {
    let m = (stream assemble (replay $tool_turn))
    (eq "stream: a tool_use turn reports stop_reason tool_use" $m.stop_reason "tool_use")
  })

  (case "stream: [DONE] and event:/blank lines are ignored" {
    let a = (replay ["event: message_start" "" "data: [DONE]"])
    (eq "stream: [DONE] and event:/blank lines are ignored" $a.blocks [])
  })

  (case "stream: a non-SSE line is kept as evidence, not dropped" {
    # when a gateway answers an error as plain JSON there is no SSE at all; those
    # lines are the only thing the caller can report, so they must survive
    let a = (replay ["{\"error\":{\"message\":\"bad key\"}}"])
    (has "stream: a non-SSE line is kept as evidence, not dropped" ($a.other | str join " ") "bad key")
  })

  (case "stream: malformed JSON on a data line is ignored, not fatal" {
    let a = (replay ["data: {not json"])
    (eq "stream: malformed JSON on a data line is ignored, not fatal" $a.blocks [])
  })

  (case "stream: a normalized event the machine does not model is retained, not lost" {
    # unreachable through the anthropic dialect on purpose — it normalizes first,
    # and the case above asserts that an unmodelled *wire* delta becomes nothing.
    # this is the guard for a future dialect emitting something new: the event
    # must land in `other` so the agent can report it, rather than vanishing.
    let a = (stream apply-event {type: "future_event", x: 1} (stream seed) false true false $no_md $no_flush)
    (has "stream: a normalized event the machine does not model is retained, not lost" ($a.other | str join " ") "future_event")
  })

  (case "stream: an empty stream leaves stop_reason null" {
    # the sentinel the agent uses to tell "no SSE at all" from "a real reply"
    let a = (replay [])
    (eq "stream: an empty stream leaves stop_reason null" $a.stop_reason null)
  })

  (case "stream: the dialect maps Anthropic event names to the normalized set" {
    let evs = (anthropic events (sse {type: "content_block_delta", index: 3, delta: {type: "text_delta", text: "x"}}))
    (eq "stream: the dialect maps Anthropic event names to the normalized set" $evs [{type: "text_delta", index: 3, text: "x"}])
  })

  (case "stream: the dialect surfaces an unmodelled Anthropic delta as nothing" {
    # rather than inventing an event the state machine would not understand
    let evs = (anthropic events (sse {type: "content_block_delta", index: 0, delta: {type: "citation_delta"}}))
    (eq "stream: the dialect surfaces an unmodelled Anthropic delta as nothing" $evs [])
  })
]

emit $results
