#!/usr/bin/env nu
# events.nu — the run event stream: append-only, tolerant of a partial write, and the
# projections everything else reads.
#
# the cases below are the properties the stream is relied on for, in the order they matter:
#   1. an event survives (round trip, fields intact, order preserved)
#   2. emitting with no stream active is a no-op, not an error — every existing caller
#      that never heard of this file must keep working
#   3. a stream being written RIGHT NOW can be read: a half-written last line is dropped,
#      never fatal (this is the case a would-be reader of a live run hits first)
#   4. the projections say the true thing: tool pairing by id, an error counted as an
#      error, a call with no result not counted as a success, folds attached to their round

use ./harness.nu *
use ../core/events.nu

def tmp-stream []: nothing -> record {
  let p = ($nu.temp-dir | path join $"events-test-(random int 100000..999999).jsonl")
  touch $p
  {path: $p}
}

def cleanup [p: any]: nothing -> nothing {
  if ($p | path exists) { rm -f $p }
}

let results = [
  (case "events: emit then read gives the event back with its fields" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "note" {hello: "world", n: 7} | ignore
    let got = (events read $s.path)
    cleanup $s.path
    (eq "events: emit then read gives the event back with its fields" (($got | length) == 1 and $got.0.hello == "world" and $got.0.n == 7) true)
  })

  (case "events: every event carries run, ts and kind" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "round.start" {n: 1} | ignore
    let e = (events read $s.path | first)
    cleanup $s.path
    (is-true "events: every event carries run, ts and kind" (
      ($e.kind == "round.start") and (($e.run | str length) > 4) and (($e.ts | str length) > 10)
    ))
  })

  (case "events: appending keeps the earlier events, in order" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    for i in [1 2 3] { events emit "note" {i: $i} | ignore }
    let got = (events read $s.path | get i)
    cleanup $s.path
    (eq "events: appending keeps the earlier events, in order" $got [1 2 3])
  })

  (case "events: no active stream means emit is a silent no-op" {
    # the default state of every caller that predates this file. a raise here would break
    # every one of them, which is why the empty case returns false rather than erroring.
    # set to "", not unset: an unset variable is what an ordinary child process has, and
    # `hide-env` on a variable that was never set raises instead of clearing it.
    $env.NU_AGENT_EVENTS = ""
    let wrote = (events emit "note" {x: 1})
    (eq "events: no active stream means emit is a silent no-op" $wrote false)
  })

  (case "events: a half-written last line is dropped, the rest still reads" {
    # exactly what a reader of a LIVE stream sees: the writer is mid-line. the line has no
    # closing brace, so it cannot parse, and the two complete events around it must survive.
    #
    # every write here carries its own trailing newline — `save` concatenates with no
    # separator, so omitting it glues two records into one unparseable line (the same trap
    # apps/wechat/reply.nu documents).
    let s = (tmp-stream)
    ('{ "kind": "note", "i": 1 }' + (char nl)) | save -f $s.path
    ('{ "kind": "note", "i": 2 }' + (char nl) + '{ "kind": "note", "i": 3') | save -f --append $s.path
    let got = (events read $s.path | get i)
    cleanup $s.path
    (eq "events: a half-written last line is dropped, the rest still reads" $got [1 2])
  })

  (case "events: reading a stream that was never created is empty, not an error" {
    (eq "events: reading a stream that was never created is empty, not an error" (events read "/nonexistent/agent-events/nope.jsonl") [])
  })

  (case "events: an empty stream summarises to zeroes, not to a crash" {
    let s = (tmp-stream)
    let sum = (events summary $s.path)
    cleanup $s.path
    (eq "events: an empty stream summarises to zeroes, not to a crash" [$sum.rounds $sum.tool_calls $sum.status] [0 0 "unknown"])
  })

  (case "events: the summary counts rounds, tools, errors, folds and tokens" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "run.start" {task: "t", model: "m"} | ignore
    events emit "round.start" {n: 1} | ignore
    events emit "tool.call" {round: 1, id: "a", name: "calc", input: {}} | ignore
    events emit "tool.result" {round: 1, id: "a", name: "calc", ok: true, ms: 4} | ignore
    events emit "tool.call" {round: 1, id: "b", name: "shell", input: {}} | ignore
    events emit "tool.result" {round: 1, id: "b", name: "shell", ok: false, ms: 9} | ignore
    events emit "round.end" {n: 1, input_tokens: 100, output_tokens: 10, stop_reason: "end_turn"} | ignore
    events emit "fold" {when: "overflow", round: 2, count: 3, before: 900, after: 100, entry: "e1"} | ignore
    events emit "run.end" {status: "done"} | ignore
    let sum = (events summary $s.path)
    cleanup $s.path
    (eq "events: the summary counts rounds, tools, errors, folds and tokens" [
      $sum.rounds $sum.tool_calls $sum.tool_errors $sum.folds $sum.input_tokens $sum.output_tokens $sum.status
    ] [1 2 1 1 100 10 "done"])
  })

  (case "events: per-tool timing is aggregated, slowest first" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "tool.result" {round: 1, id: "a", name: "read", ok: true, ms: 5} | ignore
    events emit "tool.result" {round: 1, id: "b", name: "shell", ok: true, ms: 120} | ignore
    events emit "tool.result" {round: 1, id: "c", name: "shell", ok: true, ms: 80} | ignore
    let tools = (events summary $s.path | get tools)
    cleanup $s.path
    (eq "events: per-tool timing is aggregated, slowest first" [$tools.0.name $tools.0.calls $tools.0.total_ms $tools.1.name] ["shell" 2 200 "read"])
  })

  (case "events: the trace projection pairs a tool call with its result by id" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "run.start" {task: "what is 1+1", model: "m"} | ignore
    events emit "round.start" {n: 1} | ignore
    events emit "tool.call" {round: 1, id: "x1", name: "calc", input: {expression: "1+1"}, mode: "pure"} | ignore
    events emit "tool.result" {round: 1, id: "x1", name: "calc", ok: true, ms: 3, preview: "2"} | ignore
    events emit "round.end" {n: 1, text: "two", input_tokens: 10, output_tokens: 2, stop_reason: "end_turn"} | ignore
    events emit "run.end" {status: "done"} | ignore
    let m = (events model $s.path)
    cleanup $s.path
    (eq "events: the trace projection pairs a tool call with its result by id" [
      $m.task, ($m.rounds | length), $m.rounds.0.tools.0.name, $m.rounds.0.tools.0.result, $m.rounds.0.tools.0.is_error, $m.rounds.0.text
    ] ["what is 1+1" 1 "calc" "2" false "two"])
  })

  (case "events: a call with no recorded result is an error, not a success by omission" {
    # the round a killed run died in. reporting it as fine is the failure this guards
    # against — the same mistake that once handed the model an empty result for a `find`
    # that had been killed mid-walk.
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "round.start" {n: 1} | ignore
    events emit "tool.call" {round: 1, id: "lost", name: "shell", input: {command: "find /"}} | ignore
    let t = (events model $s.path | get rounds.0.tools.0)
    cleanup $s.path
    (eq "events: a call with no recorded result is an error, not a success by omission" [$t.is_error ($t.result | str contains "no result recorded")] [true true])
  })

  (case "events: a round with no assistant text still appears as a round" {
    # a round that died before the model answered is invisible to a message-walking
    # projection. it is visible here, which is the point of projecting from the stream.
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "round.start" {n: 1} | ignore
    events emit "round.end" {n: 1, stop_reason: "timeout", input_tokens: 500, output_tokens: 0} | ignore
    let rounds = (events model $s.path | get rounds)
    cleanup $s.path
    (eq "events: a round with no assistant text still appears as a round" [($rounds | length) $rounds.0.stop_reason] [1 "timeout"])
  })

  (case "events: a fold is attached to the round it happened before" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "round.start" {n: 1} | ignore
    events emit "round.end" {n: 1, text: "a"} | ignore
    events emit "fold" {when: "proactive", round: 2, count: 3, before: 900, after: 100, entry: "e1"} | ignore
    events emit "round.start" {n: 2} | ignore
    events emit "round.end" {n: 2, text: "b"} | ignore
    let rounds = (events model $s.path | get rounds)
    cleanup $s.path
    (eq "events: a fold is attached to the round it happened before" [
      ($rounds.0.folds | length) ($rounds.1.folds | length) $rounds.1.folds.0.entry
    ] [0 1 "e1"])
  })

  (case "events: tool wall-clock time is in the stream's projection (the message walk cannot have it)" {
    let s = (tmp-stream)
    $env.NU_AGENT_EVENTS = $s.path
    events emit "round.start" {n: 1} | ignore
    events emit "tool.call" {round: 1, id: "a", name: "shell", input: {}} | ignore
    events emit "tool.result" {round: 1, id: "a", name: "shell", ok: true, ms: 321, preview: ""} | ignore
    let t = (events model $s.path | get rounds.0.tools.0)
    cleanup $s.path
    (eq "events: tool wall-clock time is in the stream's projection (the message walk cannot have it)" $t.ms 321)
  })

  (case "events: two runs get different ids and different files" {
    let a = (events new-run)
    let b = (events new-run)
    rm -f $a.path $b.path
    (is-true "events: two runs get different ids and different files" ($a.id != $b.id and $a.path != $b.path))
  })

  (case "events: a new run leaves an empty file, so 'ran but said nothing' is visible" {
    # a missing file cannot be told from "events were off for this run". an empty one can.
    let a = (events new-run)
    let exists = ($a.path | path exists)
    let lines = (events read $a.path | length)
    rm -f $a.path
    (eq "events: a new run leaves an empty file, so 'ran but said nothing' is visible" [$exists $lines] [true 0])
  })

  (case "events: prune keeps the newest N and reports what it drops" {
    let base = (events dir)
    mkdir $base
    let stamp = (random int 100000..999999)
    let names = (0..4 | each {|i| $base | path join $"prune-test-($stamp)-($i).jsonl" })
    # created one at a time with a gap between them, because `prune` orders by mtime and
    # `touch`'s own time argument wants a datetime, not the `-t` stamp a shell would take.
    for n in $names { touch $n; sleep 30ms }
    let dropped = (events prune --keep 2 | get name)
    let left = ($names | where {|n| $n | path exists })
    for n in $names { if ($n | path exists) { rm -f $n } }
    # glob the store, not just our names: other runs may exist, so compare on ours only
    let ours_dropped = ($dropped | where {|d| $d | str contains $"prune-test-($stamp)" })
    let ours_left = ($left | where {|d| $d | str contains $"prune-test-($stamp)" })
    # the two kept must be the two NEWEST, not just any two
    let kept_are_newest = (($ours_left | sort) == (($names | sort) | last 2))
    (eq "events: prune keeps the newest N and reports what it drops" [($ours_dropped | length) ($ours_left | length) $kept_are_newest] [3 2 true])
  })
]

emit $results
