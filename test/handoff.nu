#!/usr/bin/env nu
# handoff.nu — importing another agent's conversation
#
# hermetic: every transcript here is synthesised into a temp dir, in the shape
# each agent actually writes (verified against real files on this machine). the
# point is to pin the format work, not to depend on whatever happens to be in
# ~/.claude when the tests run.

use ./harness.nu *
# imported directly rather than relied on from test/config.nu, so this suite is
# self-sufficient: it runs against any config that has the harness, which is what
# lets it be committed on its own.
use ./../core/handoff.nu
use ./../core/session.nu

let tmp = ($nu.temp-dir | path join $"nu-agent-handoff-(random int 100000..999999)")
mkdir $tmp
$env.NU_SESSION_DIR = ($tmp | path join "sessions")
$env.NU_CONTEXT_DIR = ($tmp | path join "context")

# ── fixtures ──

# claude-code: {type: user|assistant, message: {role, content}, isSidechain, cwd, timestamp}
let cc = ($tmp | path join "cc.jsonl")
[
  {type: "mode", sessionId: "abc"}
  {type: "user", cwd: "/tmp/proj", timestamp: "2026-01-01T10:00:00Z", isSidechain: false, message: {role: "user", content: "what is in main.rs?"}}
  {type: "assistant", cwd: "/tmp/proj", timestamp: "2026-01-01T10:00:05Z", isSidechain: false, message: {role: "assistant", content: [
    {type: "thinking", thinking: "let me read it"}
    {type: "text", text: "It parses arguments."}
    {type: "tool_use", id: "t1", name: "Read", input: {file_path: "main.rs"}}
  ]}}
  {type: "user", cwd: "/tmp/proj", timestamp: "2026-01-01T10:00:06Z", isSidechain: false, message: {role: "user", content: [{type: "tool_result", tool_use_id: "t1", content: "fn main(){}"}]}}
  {type: "assistant", cwd: "/tmp/proj", timestamp: "2026-01-01T10:00:09Z", isSidechain: true, message: {role: "assistant", content: [{type: "text", text: "SIDECHAIN — must not be imported"}]}}
  {type: "assistant", cwd: "/tmp/proj", timestamp: "2026-01-01T10:00:10Z", isSidechain: false, message: {role: "assistant", content: [{type: "text", text: "Anything else?"}]}}
] | each {|r| $r | to json -r } | save -f $cc

# codex: session_meta + response_item{payload:{type: message, role, content[]}}
let cx = ($tmp | path join "cx.jsonl")
[
  {type: "session_meta", payload: {id: "01a0-abc", cwd: "/tmp/proj", timestamp: "2026-01-02T09:00:00Z"}}
  {type: "response_item", payload: {type: "message", role: "user", content: [{type: "input_text", text: "<environment_context>\n  <cwd>/tmp/proj</cwd>\n</environment_context>"}]}}
  {type: "response_item", payload: {type: "message", role: "user", content: [{type: "input_text", text: "add a --verbose flag"}]}}
  {type: "response_item", payload: {type: "reasoning", summary: []}}
  {type: "response_item", payload: {type: "function_call", name: "shell", arguments: "{}", call_id: "c1"}}
  {type: "response_item", payload: {type: "function_call_output", call_id: "c1", output: "ok"}}
  {type: "response_item", payload: {type: "message", role: "assistant", content: [{type: "output_text", text: "Done — added it."}]}}
] | each {|r| $r | to json -r } | save -f $cx

# pi: {type: session} + {type: message, message: {role, content}}
let pi = ($tmp | path join "pi.jsonl")
[
  {type: "session", version: 3, id: "01a0-pi", timestamp: "2026-01-03T08:00:00Z", cwd: "/tmp/proj"}
  {type: "model_change", id: "m1", provider: "pgw", modelId: "gpt-5.6-terra"}
  {type: "message", id: "a", message: {role: "system", content: "you are an assistant"}}
  {type: "message", id: "b", message: {role: "user", content: "hi"}}
  {type: "message", id: "c", message: {role: "assistant", content: [{type: "thinking", thinking: "greet"}, {type: "text", text: "Hello!"}]}}
] | each {|r| $r | to json -r } | save -f $pi

let results = [
  # ── claude-code ──
  (case "handoff: claude-code messages come out in order, text only" {
    let r = (handoff parse claude-code $cc)
    (eq "handoff: claude-code messages come out in order, text only" ($r.messages | get content) ["what is in main.rs?" "It parses arguments." "Anything else?"])
  })

  (case "handoff: claude-code sidechains are not the conversation" {
    # a sidechain is a subagent's own transcript, not this one
    let r = (handoff parse claude-code $cc)
    (lacks "handoff: claude-code sidechains are not the conversation" ($r.messages | to json -r) "SIDECHAIN")
  })

  (case "handoff: thinking and tool blocks are dropped, and tools counted" {
    let r = (handoff parse claude-code $cc)
    (eq "handoff: thinking and tool blocks are dropped, and tools counted" $r.tools_skipped 2)
  })

  (case "handoff: claude-code metadata is read from the transcript" {
    let r = (handoff parse claude-code $cc)
    (eq "handoff: claude-code metadata is read from the transcript" [$r.id $r.cwd] ["cc" "/tmp/proj"])
  })

  # ── codex ──
  (case "handoff: codex messages come from response_item/payload" {
    let r = (handoff parse codex $cx)
    (eq "handoff: codex messages come from response_item/payload" ($r.messages | get content) ["add a --verbose flag" "Done — added it."])
  })

  (case "handoff: codex harness context blocks are not the user speaking" {
    # every codex session opens by injecting <environment_context> as a user turn
    let r = (handoff parse codex $cx)
    (lacks "handoff: codex harness context blocks are not the user speaking" ($r.messages | to json -r) "environment_context")
  })

  (case "handoff: codex tool calls are counted from their own items" {
    # they are separate response_item types, not blocks inside a message
    let r = (handoff parse codex $cx)
    (eq "handoff: codex tool calls are counted from their own items" $r.tools_skipped 2)
  })

  (case "handoff: codex id and cwd come from session_meta" {
    let r = (handoff parse codex $cx)
    (eq "handoff: codex id and cwd come from session_meta" [$r.id $r.cwd] ["01a0-abc" "/tmp/proj"])
  })

  # ── pi ──
  (case "handoff: pi messages come from type:message" {
    let r = (handoff parse pi $pi)
    (eq "handoff: pi messages come from type:message" ($r.messages | get content) ["hi" "Hello!"])
  })

  (case "handoff: pi system turns are not part of the conversation" {
    let r = (handoff parse pi $pi)
    (eq "handoff: pi system turns are not part of the conversation" ($r.messages | get role) ["user" "assistant"])
  })

  (case "handoff: pi id and cwd come from the session header" {
    let r = (handoff parse pi $pi)
    (eq "handoff: pi id and cwd come from the session header" [$r.id $r.cwd] ["01a0-pi" "/tmp/proj"])
  })

  # ── parsing resilience ──
  (case "handoff: a half-written last line does not fail the read" {
    # normal while the other agent is still running
    let f = ($tmp | path join "partial.jsonl")
    ['{"type":"user","message":{"role":"user","content":"complete"},"isSidechain":false}', '{"type":"user","message":{"role":"us'] | save -f $f
    let r = (handoff parse claude-code $f)
    (eq "handoff: a half-written last line does not fail the read" ($r.messages | length) 1)
  })

  (case "handoff: an unknown agent is refused by name" {
    (throws "handoff: an unknown agent is refused by name" { handoff parse no-such-agent $cc })
  })

  # ── import ──
  (case "handoff: import stores the whole conversation" {
    let i = (handoff import claude-code $cc --into h1 --tail 1)
    (eq "handoff: import stores the whole conversation" ((session load h1).messages | length) 3)
  })

  (case "handoff: import stamps where it came from" {
    let r = (session load h1)
    (eq "handoff: import stamps where it came from" $r.handoff.from "claude-code")
  })

  (case "handoff: the stamp records how many tools were left behind" {
    (eq "handoff: the stamp records how many tools were left behind" ((session load h1).handoff.tools_skipped) 2)
  })

  (case "handoff: the stamp records the source id, not just the agent" {
    (is-true "handoff: the stamp records the source id, not just the agent" (((session load h1).handoff.source_id) | str contains "cc"))
  })

  (case "handoff: import reports how much is loaded by default" {
    let i = (handoff import claude-code $cc --into h2 --tail 1)
    (eq "handoff: import reports how much is loaded by default" $i.loaded_by_default 1)
  })

  (case "handoff: a session with no turns is refused rather than importing nothing" {
    let empty = ($tmp | path join "empty.jsonl")
    "[]" | save -f $empty
    (throws "handoff: a session with no turns is refused rather than importing nothing" { handoff import claude-code $empty --into h3 })
  })

  (case "handoff: the note names the source agent" {
    (has "handoff: the note names the source agent" (handoff note (session load h1).handoff 1 3) "claude-code")
  })

  (case "handoff: the note says how much was left out" {
    (has "handoff: the note says how much was left out" (handoff note (session load h1).handoff 1 3) "2 earlier messages were NOT loaded")
  })

  (case "handoff: the note warns that the older tools are not this runtime's" {
    # the point the user asked for: replaying an earlier tool may not be compatible
    let n = (handoff note (session load h1).handoff 1 3)
    (has "handoff: the note warns that the older tools are not this runtime's" $n "do not assume an earlier tool ran in this environment")
  })

  (case "handoff: the note is silent about tools when none were skipped" {
    let n = (handoff note {from: "pi", source_id: "x", imported: "now", tools_skipped: 0} 2 2)
    (lacks "handoff: the note is silent about tools when none were skipped" $n "tool calls from")
  })

  # ── the listing ──
  (case "handoff: sources reports what is reachable" {
    let s = (handoff sources)
    (is-true "handoff: sources reports what is reachable" (($s | get agent) == ["claude-code" "codex" "pi"]))
  })
]

rm -rf $tmp
emit $results
