#!/usr/bin/env nu
# session.nu — persistence and resume
#
# hermetic except for one case, which has to run the loop to prove the invariant
# that matters: a run whose context was folded must still store the UNFOLDED
# history. that one is guarded on credentials.

use ./harness.nu *

let tmp = ($nu.temp-dir | path join $"nu-agent-session-(random int 100000..999999)")
mkdir $tmp
$env.NU_SESSION_DIR = ($tmp | path join "sessions")
$env.NU_CONTEXT_DIR = ($tmp | path join "context")

let sample = {
  id: "s1"
  status: "done"
  title: "a stored run"
  created: "2026-01-01 00:00:00"
  provider: "anthropic"
  model: "m"
  system: "be terse"
  skill: ["/tmp/skill.md"]
  tools: {modules: ["read" "calc"], mcp: [["nu" "server.nu"]]}
  cwd: "/tmp"
  budget: {context_budget: 1000, keep_recent: 4, max_tokens: 512, max_output: 8000, max_rounds: null}
  messages: [
    {role: "user", content: "the original task"}
    {role: "assistant", content: [{type: "text", text: "ok"}]}
  ]
  images: [{index: 0, path: "/tmp/pic.png"}]
  counters: {rounds: 1, tool_calls: 0, last_input_tokens: 12, stop_reason: "end_turn"}
  folds: []
  context_entries: []
  parent: "ses-parent"
  depth: 1
}

$sample | session store | ignore

let results = [
  # ── round trip ──
  (case "session: store then load returns the same record" {
    let r = (session load "s1")
    (eq "session: store then load returns the same record" [$r.id $r.model $r.counters.rounds] ["s1" "m" 1])
  })

  (case "session: storing stamps an updated time" {
    let r = (session load "s1")
    (is-true "session: storing stamps an updated time" (($r | get --optional updated | default "") | is-not-empty))
  })

  (case "session: an explicit id is used, not a generated one" {
    (is-true "session: an explicit id is used, not a generated one" (session exists "s1"))
  })

  (case "session: an unknown id raises and says where to look" {
    let m = (try { session load "nope"; "" } catch {|e| $e.msg })
    (has "session: an unknown id raises and says where to look" $m "session list")
  })

  # ── listing ──
  (case "session: list reports one row per stored session" {
    (eq "session: list reports one row per stored session" ((session list) | length) 1)
  })

  (case "session: list carries the fields a picker needs" {
    let row = (session list | first)
    (eq "session: list carries the fields a picker needs" ($row | columns | sort) ["depth" "from" "id" "messages" "model" "parent" "provider" "rounds" "status" "title" "updated"])
  })

  (case "session: last returns the most recently updated" {
    {id: "s2", status: "done", messages: [], model: "m", provider: "anthropic"} | session store | ignore
    (eq "session: last returns the most recently updated" ((session last).id) "s2")
  })

  (case "session: list is newest first" {
    (eq "session: list is newest first" ((session list | first).id) "s2")
  })

  (case "session: an unparseable session file does not break the listing" {
    # a half-written file must not take down the command that would let you see
    # what happened
    "{not json" | save -f ($tmp | path join "sessions" | path join "broken.json")
    (eq "session: an unparseable session file does not break the listing" ((session list) | length) 2)
  })

  # ── inspection ──
  (case "session: show --index returns one raw message" {
    let m = (session show "s1" --index 0)
    (eq "session: show --index returns one raw message" $m.role "user")
  })

  (case "session: show --index rejects an out-of-range index" {
    (throws "session: show --index rejects an out-of-range index" { session show "s1" --index 99 })
  })

  (case "session: show --full dumps the messages" {
    let r = (session show "s1" --full)
    (eq "session: show --full dumps the messages" ($r.messages | length) 2)
  })

  # ── what is stored as provenance ──
  (case "session: tools are stored as module NAMES, not resolved schemas" {
    # a frozen input_schema list would replay a stale tool set on resume
    let r = (session load "s1")
    (eq "session: tools are stored as module NAMES, not resolved schemas" $r.tools.modules ["read" "calc"])
  })

  (case "session: skills are stored as PATHS, so an edited skill is re-read" {
    let r = (session load "s1")
    (eq "session: skills are stored as PATHS, so an edited skill is re-read" $r.skill ["/tmp/skill.md"])
  })

  (case "session: images are stored as paths, never as base64" {
    # base64 would make a session holding one screenshot tens of megabytes
    let r = (session load "s1")
    (eq "session: images are stored as paths, never as base64" $r.images [{index: 0, path: "/tmp/pic.png"}])
  })

  (case "session: subagent lineage survives the round trip" {
    let r = (session load "s1")
    (eq "session: subagent lineage survives the round trip" [$r.parent $r.depth] ["ses-parent" 1])
  })

  # ── the loop's refusal to clobber ──
  (case "session: writing to an existing id without --resume is refused" {
    # silently appending to a stored run is the failure worth engineering against
    let m = (try { agent "hi" --session s1 --max-tokens 8; "" } catch {|e| $e.msg })
    (has "session: writing to an existing id without --resume is refused" $m "already exists")
  })

  (case "session: --resume with an empty store is refused" {
    let m = (try {
        let saved = $env.NU_SESSION_DIR
        $env.NU_SESSION_DIR = ($tmp | path join "empty")
        let out = (try { agent "hi" --resume --max-tokens 8; "" } catch {|e| $e.msg })
        $env.NU_SESSION_DIR = $saved
        $out
      } catch {|e| $e.msg })
    (has "session: --resume with an empty store is refused" $m "store is empty")
  })

  # ── maintenance ──
  (case "session: prune --dry-run reports without deleting" {
    let doomed = (session prune --keep 1 --dry-run)
    (is-true "session: prune --dry-run reports without deleting" ((($doomed | length) > 0) and (session exists "s1")))
  })

  (case "session: prune --keep N deletes the rest" {
    session prune --keep 1 | ignore
    (is-true "session: prune --keep N deletes the rest" ((session list | length) == 1))
  })

  # ── the window: what a resume loads, and what it must not lose ──
  (case "session: window splits a history into prefix and loaded" {
    let prior = {messages: [{role: "user", content: "1"} {role: "user", content: "2"} {role: "user", content: "3"}]}
    let w = (session window $prior 2)
    (eq "session: window splits a history into prefix and loaded" [($w.prefix | length) ($w.loaded | length)] [1 2])
  })

  (case "session: window with no tail loads everything" {
    let prior = {messages: [{role: "user", content: "1"} {role: "user", content: "2"}]}
    let w = (session window $prior null)
    (eq "session: window with no tail loads everything" [($w.prefix | length) ($w.loaded | length)] [0 2])
  })

  (case "session: window takes the tail the session recorded" {
    # a handoff sets one, because another agent's transcript is long
    let prior = {messages: [{role: "user", content: "1"} {role: "user", content: "2"} {role: "user", content: "3"}], handoff: {tail: 1}}
    let w = (session window $prior null)
    (eq "session: window takes the tail the session recorded" ($w.loaded | length) 1)
  })

  (case "session: an explicit tail beats the one the session recorded" {
    let prior = {messages: [{role: "user", content: "1"} {role: "user", content: "2"} {role: "user", content: "3"}], handoff: {tail: 1}}
    let w = (session window $prior 3)
    (eq "session: an explicit tail beats the one the session recorded" ($w.loaded | length) 3)
  })

  (case "session: a tail larger than the history loads all of it" {
    let prior = {messages: [{role: "user", content: "1"}]}
    let w = (session window $prior 99)
    (eq "session: a tail larger than the history loads all of it" [($w.prefix | length) ($w.loaded | length)] [0 1])
  })

  (case "session: a fresh session has an empty window" {
    let w = (session window null null)
    (eq "session: a fresh session has an empty window" [($w.prefix | length) ($w.loaded | length)] [0 0])
  })

  # ── chat keeps a conversation ──
  (case "session: agent chat writes a turn to a named session" {
    if not (needs-creds) {
      skipped "session: agent chat writes a turn to a named session" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      agent chat "say nothing but the word: one" --session chatty --max-tokens 64 | ignore
      let rec = (session load chatty)
      (eq "session: agent chat writes a turn to a named session" [($rec.messages | length) ($rec.status)] [2 "chat"])
    }
  })

  (case "session: a resumed chat sees the earlier turn" {
    if not (needs-creds) {
      skipped "session: a resumed chat sees the earlier turn" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      agent chat "reply with just the number 41" --session numbers --max-tokens 128 | ignore
      let r = (agent chat "what number did I ask for? reply with only it" --resume --session numbers --max-tokens 128 --json)
      let rec = (session load numbers)
      (is-true "session: a resumed chat sees the earlier turn" (
        (($rec.messages | length) == 4) and (($r.content | to json -r) | str contains "41")
      ))
    }
  })

  (case "session: a resumed chat with a tail does NOT truncate the store" {
    # the failure this guards: loading a window and then saving `prefix ++ this
    # run`, but forgetting the prefix — which silently drops the older history
    if not (needs-creds) {
      skipped "session: a resumed chat with a tail does NOT truncate the store" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      agent chat "remember the word marmalade, then say ok" --session tailed --max-tokens 128 | ignore
      agent chat "and now say ok again" --resume --session tailed --max-tokens 128 | ignore
      let before = ((session load tailed).messages | length)
      agent chat "one more ok" --resume --session tailed --tail 2 --max-tokens 128 | ignore
      let after = ((session load tailed).messages | length)
      (eq "session: a resumed chat with a tail does NOT truncate the store" $after ($before + 2))
    }
  })

  # ── the invariant, with the loop actually running ──
  (case "session: a folded run stores the UNFOLDED history" {
    if not (needs-creds) {
      skipped "session: a folded run stores the UNFOLDED history" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      # a tiny budget forces the proactive fold, several times over. the stored
      # messages must be the real history: storing the working copy would put
      # `[folded] item N …` placeholders in the file, and resuming would hand the
      # model those instead of its own conversation.
      let sid = "folded-run"
      agent "Use the calc tool three times: 1+1, 2+2, 3+3. Then say 'done'." --tools-from [calc] --session $sid --context-budget 600 --max-tokens 512 | ignore
      let rec = (session load $sid)
      let raw = ($rec.messages | to json -r)
      (is-true "session: a folded run stores the UNFOLDED history" (
        (not ($raw | str contains "[folded]")) and (($rec.messages | length) > 2)
      ))
    }
  })

  (case "session: the working copy and the canonical copy can differ" {
    if not (needs-creds) {
      skipped "session: the working copy and the canonical copy can differ" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let sid = "both-copies"
      let r = (agent "Use the calc tool three times: 1+1, 2+2, 3+3." --tools-from [calc] --session $sid --context-budget 600 --max-tokens 512 --json)
      # both are reported, and the canonical one is the longer, placeholder-free one
      (is-true "session: the working copy and the canonical copy can differ" (
        (($r | get --optional canonical) != null)
        and (not (($r.canonical | to json -r) | str contains "[folded]"))
        and (($r.canonical | length) >= ($r.messages | length))
      ))
    }
  })
]

rm -rf $tmp
emit $results
