#!/usr/bin/env nu
# openai.nu — the OpenAI dialect's translation, replayed from canned bytes
#
# hermetic. the live path is covered by e2e; what needs pinning here is the
# translation between two message shapes, and the streaming state that has no
# counterpart on the Anthropic side.
#
# the first case is a regression: `flatten` collapses a single-element
# `tool_calls` array into a bare object, which every endpoint rejects — and it
# did so only when the array happened to hold exactly one entry.

use ./harness.nu *
use ./../core/provider/openai.nu

# the translation is the subject here, not authentication. a dummy key keeps
# these hermetic — without one they quietly depended on whatever OPENAI_API_KEY
# happened to be in the ambient environment, and went red the moment it was not.
$env.OPENAI_API_KEY = "test-key-not-used"
$env.OPENAI_BASE_URL = "https://example.invalid/v1"

let tools = (expose from-module calc)

# build a mixed-shape block list the way the runtime actually gets one: from
# JSON. nu cannot unify a literal list of differently-shaped records — it fails
# at the literal, not at anything informative — and `append` hits the same wall.
# a resumed session arrives as parsed JSON too, so this is the real shape, not a
# workaround.
def blocks [json: string]: nothing -> list { $json | from json }

let results = [
  # ── the regression ──
  (case "openai: ONE tool call becomes an ARRAY, not a bare object" {
    # measured: `[tool] | flatten` hoists nested records while `[[tool][tool]] |
    # flatten` does not, so the same code was right with two tool calls and wrong
    # with one. an object where the wire wants an array is a rejected request.
    let m = (openai messages [{role: "assistant", content: [{type: "tool_use", id: "c1", name: "calc", input: {expr: "1"}}]}] null)
    # a list of records describes as table<...>, so both prefixes mean "array"
    let d = ($m.0.tool_calls | describe)
    (is-true "openai: ONE tool call becomes an ARRAY, not a bare object" (($d | str starts-with "list") or ($d | str starts-with "table")))
  })

  (case "openai: tool call arguments are a JSON STRING, not an object" {
    # this wire quotes them; sending an object is a 400
    let m = (openai messages [{role: "assistant", content: [{type: "tool_use", id: "c1", name: "calc", input: {expr: "1+1"}}]}] null)
    (eq "openai: tool call arguments are a JSON STRING, not an object" ($m.0.tool_calls.0.function.arguments | describe) "string")
  })

  (case "openai: two tool calls stay two entries" {
    let two = (blocks '[{"type":"tool_use","id":"c1","name":"calc","input":{"expr":"1"}},{"type":"tool_use","id":"c2","name":"calc","input":{"expr":"2"}}]')
    let m = (openai messages [{role: "assistant", content: $two}] null)
    (eq "openai: two tool calls stay two entries" ($m.0.tool_calls | length) 2)
  })

  # ── message translation ──
  (case "openai: the system prompt is hoisted into a leading message" {
    let m = (openai messages [{role: "user", content: "hi"}] "be terse")
    (eq "openai: the system prompt is hoisted into a leading message" [$m.0.role $m.0.content] ["system" "be terse"])
  })

  (case "openai: no system prompt means no system message" {
    let m = (openai messages [{role: "user", content: "hi"}] null)
    (eq "openai: no system prompt means no system message" ($m | length) 1)
  })

  (case "openai: a tool result becomes its own role:tool message" {
    let m = (openai messages [{role: "user", content: [
      {type: "tool_result", tool_use_id: "c1", content: "42", is_error: false}
    ]}] null)
    (eq "openai: a tool result becomes its own role:tool message" [$m.0.role $m.0.tool_call_id $m.0.content] ["tool" "c1" "42"])
  })

  (case "openai: a tool result followed by text becomes two messages" {
    # canonical keeps them in one turn; this wire wants them apart, and in order.
    #
    # built with `append`, not as one literal: nu cannot infer a single element
    # type for a literal list of differently-shaped records, and fails at the
    # literal rather than anywhere useful. the loop never writes such a literal
    # (it appends), which is why this only ever showed up in a test.
    let mixed = (blocks '[{"type":"tool_result","tool_use_id":"c1","content":"42","is_error":false},{"type":"text","text":"now summarise"}]')
    let m = (openai messages [{role: "user", content: $mixed}] null)
    (eq "openai: a tool result followed by text becomes two messages" ($m | get role) ["tool" "user"])
  })

  (case "openai: a plain string user turn stays a plain string" {
    # the shape every endpoint expects for the common case
    let m = (openai messages [{role: "user", content: "just text"}] null)
    (eq "openai: a plain string user turn stays a plain string" ($m.0.content | describe) "string")
  })

  (case "openai: an image block becomes an image_url data URI" {
    let mixed = (blocks '[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAA"}},{"type":"text","text":"what is this"}]')
    let m = (openai messages [{role: "user", content: $mixed}] null)
    (eq "openai: an image block becomes an image_url data URI" $m.0.content.0.image_url.url "data:image/png;base64,AAA")
  })

  (case "openai: thinking blocks are dropped on the way out" {
    # this wire has no field for them, and an unknown key is a 400 on most
    # endpoints; the Anthropic path keeps them because its server needs the
    # signature returned
    let mixed = (blocks '[{"type":"thinking","thinking":"hmm","signature":"s"},{"type":"text","text":"answer"}]')
    let m = (openai messages [{role: "assistant", content: $mixed}] null)
    (eq "openai: thinking blocks are dropped on the way out" ($m.0.content) "answer")
  })

  # ── tools ──
  (case "openai: tool definitions take the function wrapper" {
    let t = (openai tools $tools | first)
    (eq "openai: tool definitions take the function wrapper" $t.type "function")
  })

  (case "openai: input_schema becomes the function's parameters" {
    # the one field name that differs between the two tool formats
    let t = (openai tools $tools | first)
    (eq "openai: input_schema becomes the function's parameters" ($t.function.parameters.required) ["expr"])
  })

  (case "openai: every tool survives the translation" {
    let t = (openai tools ([calc read write] | each {|m| expose from-module $m } | reduce --fold [] {|x, acc| $acc | append $x }))
    (eq "openai: every tool survives the translation" ($t | length) 5)
  })

  # ── request ──
  (case "openai: usage is requested explicitly when streaming" {
    # REQUIRED: without include_usage this wire omits usage from the stream, so
    # the loop's token count stays 0 and proactive folding never fires — the
    # symptom is a mysterious overflow, not an error
    let r = (openai request {model: "m", max_tokens: 8, messages: [], system: null, temperature: null, tools: [], stream: true})
    (eq "openai: usage is requested explicitly when streaming" $r.body.stream_options.include_usage true)
  })

  (case "openai: no stream_options when not streaming" {
    let r = (openai request {model: "m", max_tokens: 8, messages: [], system: null, temperature: null, tools: [], stream: false})
    (eq "openai: no stream_options when not streaming" ($r.body | get --optional stream_options) null)
  })

  (case "openai: the URL follows the SDK convention (base includes the version)" {
    # OPENAI_BASE_URL carries /v1, as it does for every OpenAI SDK — which is
    # also what lets a gateway with no /v1 at all be pointed at directly
    let r = (openai request {model: "m", max_tokens: 8, messages: [], system: null, temperature: null, tools: [], stream: false})
    (has "openai: the URL follows the SDK convention (base includes the version)" $r.url "/chat/completions")
  })

  (case "openai: absent temperature and tools are omitted, never sent as null" {
    let r = (openai request {model: "m", max_tokens: 8, messages: [], system: null, temperature: null, tools: [], stream: false})
    (eq "openai: absent temperature and tools are omitted, never sent as null" ($r.body | columns | sort) ["max_tokens" "messages" "model"])
  })

  # ── response ──
  (case "openai: finish_reason tool_calls maps to stop_reason tool_use" {
    let b = {id: "x", model: "m", choices: [{finish_reason: "tool_calls", message: {role: "assistant", content: ""}}], usage: {prompt_tokens: 1, completion_tokens: 2}}
    (eq "openai: finish_reason tool_calls maps to stop_reason tool_use" (openai response $b).stop_reason "tool_use")
  })

  (case "openai: finish_reason length maps to max_tokens" {
    let b = {id: "x", model: "m", choices: [{finish_reason: "length", message: {content: "cut off"}}], usage: {}}
    (eq "openai: finish_reason length maps to max_tokens" (openai response $b).stop_reason "max_tokens")
  })

  (case "openai: usage token names are translated" {
    let b = {id: "x", model: "m", choices: [{finish_reason: "stop", message: {content: "hi"}}], usage: {prompt_tokens: 11, completion_tokens: 4}}
    let u = (openai response $b).usage
    (eq "openai: usage token names are translated" [$u.input_tokens $u.output_tokens] [11 4])
  })

  (case "openai: a tool call in the response becomes a canonical tool_use block" {
    let b = {id: "x", model: "m", choices: [{finish_reason: "tool_calls", message: {content: null, tool_calls: [{id: "c1", type: "function", function: {name: "calc", arguments: "{\"expr\":\"2+2\"}"}}]}}], usage: {}}
    let blk = ((openai response $b).content | where type == "tool_use" | first)
    (eq "openai: a tool call in the response becomes a canonical tool_use block" [$blk.id $blk.name $blk.input] ["c1" "calc" {expr: "2+2"}])
  })

  (case "openai: malformed tool arguments do not take the response down" {
    let b = {id: "x", model: "m", choices: [{finish_reason: "tool_calls", message: {tool_calls: [{id: "c1", function: {name: "calc", arguments: "{not json"}}]}}], usage: {}}
    let blk = ((openai response $b).content | where type == "tool_use" | first)
    (eq "openai: malformed tool arguments do not take the response down" $blk.input {})
  })

  (case "openai: reasoning_content becomes a thinking block" {
    let b = {id: "x", model: "m", choices: [{finish_reason: "stop", message: {content: "answer", reasoning_content: "I thought about it"}}], usage: {}}
    let th = ((openai response $b).content | where type == "thinking" | first)
    (eq "openai: reasoning_content becomes a thinking block" $th.thinking "I thought about it")
  })

  (case "openai: a response with no choices is an error, not an empty message" {
    # returning an empty message would read downstream as "finished, nothing to
    # say", which is indistinguishable from a real empty reply
    (throws "openai: a response with no choices is an error, not an empty message" {
      openai response {id: "x", choices: []}
    })
  })

  # ── streaming ──
  (case "openai: the first frame synthesizes a message_start" {
    let r = (openai events 'data: {"id":"x","model":"m","choices":[{"index":0,"delta":{"role":"assistant"}}]}' {})
    (eq "openai: the first frame synthesizes a message_start" ($r.events.0.type) "message_start")
  })

  (case "openai: message_start is emitted once, not per frame" {
    let a = (openai events 'data: {"id":"x","model":"m","choices":[{"delta":{"role":"assistant"}}]}' {})
    let b = (openai events 'data: {"choices":[{"delta":{"content":"hi"}}]}' $a.state)
    (eq "openai: message_start is emitted once, not per frame" (($b.events | where type == "message_start" | length)) 0)
  })

  (case "openai: text fragments accumulate under one synthesized block" {
    let a = (openai events 'data: {"choices":[{"delta":{"content":"a"}}]}' {})
    let b = (openai events 'data: {"choices":[{"delta":{"content":"b"}}]}' $a.state)
    let starts = (($a.events | append $b.events) | where type == "block_start")
    (eq "openai: text fragments accumulate under one synthesized block" ($starts | length) 1)
  })

  (case "openai: a tool call fragment carries no id — the state supplies its block index" {
    # this is the whole reason `events` is stateful: fragment 2 of tool_call 0
    # has only `index: 0`, nothing to attach the arguments to
    let a = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"calc","arguments":"{\"expr\":"}}]}}]}' {})
    let b = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"2+2\"}"}}]}}]}' $a.state)
    let delta = ($b.events | where type == "tool_input_delta" | first)
    (is-true "openai: a tool call fragment carries no id — the state supplies its block index" ($delta.index == ($a.events | where type == "block_start" | first).index))
  })

  (case "openai: two tool call streams get distinct block indices" {
    let a = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"calc"}}]}}]}' {})
    let b = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c2","function":{"name":"calc"}}]}}]}' $a.state)
    let starts = (($a.events | append $b.events) | where type == "block_start")
    (eq "openai: two tool call streams get distinct block indices" ($starts | get index) [0 1])
  })

  (case "openai: re-seeing a known tool index does not open a second block" {
    let a = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"calc"}}]}}]}' {})
    let b = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}' $a.state)
    (eq "openai: re-seeing a known tool index does not open a second block" (($b.events | where type == "block_start" | length)) 0)
  })

  (case "openai: a finish frame closes every open block" {
    # this wire has no block_stop marker. the loop parses a tool_use block's
    # accumulated JSON at block_stop, so without this the model would get a raw
    # string where it expects an object.
    let a = (openai events 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"calc","arguments":"{}"}}]}}]}' {})
    let b = (openai events 'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}' $a.state)
    (eq "openai: a finish frame closes every open block" (($b.events | where type == "block_stop" | length)) 1)
  })

  (case "openai: a finish frame reports the translated stop_reason" {
    let b = (openai events 'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}' {})
    (eq "openai: a finish frame reports the translated stop_reason" (($b.events | where type == "message_delta" | first).stop_reason) "tool_use")
  })

  (case "openai: a usage-only frame has empty choices and is not malformed" {
    # this is exactly why include_usage has to be requested; the frame that
    # carries usage carries nothing else
    let b = (openai events 'data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":1}}' {started: true, next: 0, text: null, thinking: null, tools: {}})
    let d = ($b.events | where type == "message_delta" | first)
    (eq "openai: a usage-only frame has empty choices and is not malformed" $d.usage.input_tokens 7)
  })

  (case "openai: [DONE] is ignored" {
    let b = (openai events 'data: [DONE]' {})
    (eq "openai: [DONE] is ignored" ($b.events | length) 0)
  })

  (case "openai: reasoning fragments become thinking deltas" {
    let b = (openai events 'data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}' {})
    (is-true "openai: reasoning fragments become thinking deltas" (($b.events | where type == "thinking_delta" | length) == 1))
  })

  (case "openai: state survives a round trip through the canonical machine" {
    # the state rides in the stream accumulator; if it were dropped, the second
    # tool fragment would have nowhere to attach
    use ./../core/provider/stream.nu
    let no_md = {|st, c, o| {state: $st, out: ""}}
    let no_flush = {|st, o| {state: $st, out: ""}}
    let lines = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"calc","arguments":"{\"expr\":"}}]}}]}'
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"2+2\"}"}}]}}]}'
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}'
    ]
    let a = ($lines | reduce --fold (stream seed) {|l, acc|
      stream step-line $l $acc {|line, st| openai events $line $st } false true false $no_md $no_flush
    })
    let m = (stream assemble $a)
    let t = ($m.content | where type == "tool_use" | first)
    (eq "openai: state survives a round trip through the canonical machine" $t.input {expr: "2+2"})
  })
]

emit $results
