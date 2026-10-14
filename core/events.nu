# events.nu — one run, one append-only event stream
#
#   let r = (events new-run)
#   $env.NU_AGENT_EVENTS = $r.path        # the loop (and its tool subprocesses) emit here
#   events emit "run.start" {model: "…"}
#   events read  $r.path | events summary
#   events model $r.path                  # → the same shape trace.nu renders
#
# ── why a stream and not four readers ──
# before this file, four different things read the same run through four different
# shapes: `--json` returned the final record, session.nu persisted the message list,
# trace.nu rebuilt rounds by WALKING the messages (pairing tool_use with tool_result),
# and the WeChat bridge printed its own progress as it went. they could disagree, and
# did: a fold is invisible to trace.nu, a tool's wall-clock time exists in none of
# them, and a run that fell over mid-round left a stored session with no record of
# what killed it.
#
# the event stream is the ONE record of what happened, and everything above is a
# projection of it. the two rules that make that work:
#
#   1. append-only, and flat. one JSON object per line, `kind` plus fields, no nesting
#      that a reader has to know the shape of. a partial last line (a run killed
#      mid-write) is dropped by the reader rather than crashing it.
#   2. emitted by the process that OWNS the fact. the parent emits round and tool
#      events because it is the one waiting on them; a tool subprocess emits its own
#      (the WeChat `reply` tool records that a message went out) because only it knows.
#      the shared writer is a file, and appends of a line are atomic enough for that.
#
# ── what it is NOT ──
# it is not a log for humans: nothing here is formatted, and reading it is meant to go
# through a projection. and it is not a substitute for the session store — a session is
# the RESUMPTION format (canonical messages, append-only), a stream is the RECORD of a
# run. one run may continue a session; the ids are carried in the events so the two can
# be joined after the fact.

# every kind this file's projections understand. a stream may carry kinds not listed
# (forward compatibility), but a projection that reads a listed kind can rely on its
# fields — and `emit` is lenient on purpose: losing an event is better than losing a run.
export const KINDS = [
  "run.start"     # task, model, provider, tools, modules, session, budget
  "run.end"       # status, rounds, tool_calls, tokens, ms, text_bytes
  "run.error"     # where, reason
  "round.start"   # n, messages, est_tokens
  "round.end"     # n, ms, input_tokens, output_tokens, stop_reason, text_bytes, cache_read
  "tool.call"     # round, id, name, input, mode
  "tool.result"   # round, id, name, ok, ms, bytes, error, mode
  "fold"          # when (proactive|overflow), round, count, before, after, entry
  "gate"          # tool, decision, reason
  "reply.sent"    # n, bytes  (the WeChat channel; emitted by the tool, in a subprocess)
  "note"          # free-form, by whoever wants to leave a marker
]

# ── where a run's stream lives ──
# under the data dir, one file per run, named by its id. NOT under the temp dir: a run's
# record should outlive a reboot, and the whole point of keeping it is to be able to ask
# afterwards what happened — which is exactly when the temp dir has already been swept.
export def dir []: nothing -> path {
  $nu.data-dir | path join "agent-events"
}

export def path-of [id: string]: nothing -> path {
  dir | path join $"($id).jsonl"
}

export def run-id []: nothing -> string {
  let t = (date now | format date "%Y%m%d-%H%M%S")
  $"run-($t)-(random int 1000..9999)"
}

def ts-now []: nothing -> string {
  date now | format date "%Y-%m-%dT%H:%M:%S%.3f"
}

# start a stream. returns {id, path} — the caller publishes the path into
# $env.NU_AGENT_EVENTS, because a custom command's environment change does not
# propagate back out to its caller in nushell.
export def new-run [--label: string]: nothing -> record {
  let id = (run-id)
  let p = (path-of $id)
  mkdir (dir)
  # create it now, not on first emit: a run that dies before its first event is still a
  # run that happened, and "the file exists and is empty" says that where a missing file
  # cannot be told from "events were off".
  touch $p
  {id: $id, path: $p, label: ($label | default "")}
}

# the stream this process should write to: the explicit path when given, else whatever
# the run published into the environment, else nothing at all (events are then a no-op,
# which is what every existing caller that never heard of this file gets).
export def active []: nothing -> any {
  let p = ($env.NU_AGENT_EVENTS? | default "")
  if ($p | is-empty) { null } else { $p }
}

def run-of [path: any]: nothing -> string {
  ($path | path parse | get stem)
}

# append one event. returns false when there is no stream to write to, so a caller can
# tell "recorded" from "not recording" without checking the environment itself.
#
# the try/catch is deliberate and narrow in what it swallows: a stream that cannot be
# written (a full disk, a deleted directory) must not take the run down with it. the
# event is a record OF the work, never a precondition for it.
export def emit [kind: string, data: record]: nothing -> bool {
  let p = (active)
  if $p == null { return false }
  try {
    let line = ({run: (run-of $p), ts: (ts-now), kind: $kind} | merge $data | to json -r)
    # the trailing newline is load-bearing: `save --append` concatenates with NO
    # separator, so without it two events land on one line and the reader sees one
    # malformed object. (measured the hard way in apps/wechat/reply.nu.)
    (($line + (char nl)) | save -f --append $p)
    true
  } catch {
    false
  }
}

# every event in a file, oldest first. a line that cannot be parsed is DROPPED, not
# raised on: the last line of a live stream is a line being written right now, and a
# projection that refuses to read a running stream is useless for the thing streams
# are most wanted for.
export def read [path: any]: nothing -> list {
  if ($path == null) or (not ($path | path exists)) { return [] }
  open --raw $path
  | lines
  | compact
  | each {|l| try { $l | from json } catch { null } }
  | compact
}

# single element → list. nu's own inference is what makes this necessary: a list holding
# exactly one record comes back describing as `record`, so anything that walks a grouped
# result has to normalise before it can index or iterate.
def as-list [x: any]: nothing -> list {
  let d = ($x | describe)
  if (($d | str starts-with "list") or ($d | str starts-with "table")) { $x } else { [$x] }
}

def since-epoch [ts: string]: nothing -> int {
  # the ts format is ours, so parse it ours; a hand-edited line falls back to 0 rather
  # than taking a projection down
  try { ($ts | into datetime | into int) } catch { 0 }
}

# ── projection: the counters ──
# what a caller wants to know after a run, without reading the transcript.
export def summary [path: any]: nothing -> record {
  let e = (read $path)
  if ($e | is-empty) {
    return {run: (run-of $path), events: 0, rounds: 0, tool_calls: 0, tool_errors: 0
            folds: 0, input_tokens: 0, output_tokens: 0, ms: 0, status: "unknown", tools: []}
  }
  # `default {}` rather than a bare null: a stream with events but no run.start/run.end is a
  # run that fell over before it could say it started, and reading it must still work.
  let start = ($e | where kind == "run.start" | first | default {})
  let end = ($e | where kind == "run.end" | last | default {})
  let results = ($e | where kind == "tool.result")
  # grouped by name, then walked with `columns` rather than `transpose`: transpose needs every
  # cell to be the same shape, and a group holding one row is a record where a group holding
  # two is a table — measured, that mismatch fails with a bare "Unsupported input". the
  # as-list guard below is the same hazard one level down.
  let grouped = ($results | group-by name)
  let per_tool = (
    $grouped | columns | each {|n|
      let items = (as-list ($grouped | get $n))
      {
        name: $n
        calls: ($items | length)
        errors: ($items | where {|r| not ($r | get --optional ok | default true)} | length)
        # the trailing 0 is not decoration: `math sum` on an EMPTY list raises
        # "Unsupported input" rather than returning 0 (measured), and the empty case is
        # ordinary here — a tool that was called and never returned has no timing.
        total_ms: ($items | each {|r| $r | get --optional ms | default 0 } | append 0 | math sum)
      }
    } | sort-by total_ms -r
  )
  # same trailing-0 guard, for a stream with no completed round in it
  let sum_of = {|field: string|
    $e | where kind == "round.end" | each {|x| $x | get --optional $field | default 0 } | append 0 | math sum
  }
  {
    run: (run-of $path)
    events: ($e | length)
    rounds: ($e | where kind == "round.end" | length)
    tool_calls: ($results | length)
    tool_errors: ($results | where {|r| not ($r | get --optional ok | default true)} | length)
    folds: ($e | where kind == "fold" | length)
    input_tokens: (do $sum_of "input_tokens")
    output_tokens: (do $sum_of "output_tokens")
    ms: ((since-epoch ($e | last | get ts)) - (since-epoch ($e | first | get ts)))
    status: ($end | get --optional status | default (if ($e | where kind == "run.error" | is-not-empty) { "error" } else { "running" }))
    task: ($start | get --optional task | default "")
    model: ($start | get --optional model | default "")
    tools: $per_tool
  }
}

# ── projection: the trace ──
# the same shape core/trace.nu builds by walking the message list, built instead from
# the stream. two things the message walk cannot produce and this can: each tool's
# wall-clock time, and the rounds that failed (a round with no assistant message is
# invisible to a walk).
export def model [path: any]: nothing -> record {
  let e = (read $path)
  let start = ($e | where kind == "run.start" | first)
  let calls = ($e | where kind == "tool.call")
  # id → result row. built with `reduce`, not `transpose`: transpose's rest arguments are
  # column names and it errors with "name not found" on anything else, which is a confusing
  # way to discover a typo in a name that was never a command.
  let results = (
    $e | where kind == "tool.result"
    | reduce --fold {} {|r, acc| $acc | upsert ($r | get --optional id | default "") $r }
  )

  # one round record per `round.start`; the results that name it are attached below.
  # built from the events rather than from `round.end` so a round that never finished
  # (a timeout, a crash, an overflow retry) still appears — with what it managed to do.
  mut rounds = []
  for rs in ($e | where kind == "round.start") {
    let n = ($rs.n? | default 0)
    let re = ($e | where kind == "round.end" and n == $n | last)
    let my_calls = ($calls | where {|c| ($c.round? | default (-1)) == $n })
    let tools = ($my_calls | each {|c|
        let res = ($results | get --optional ($c.id? | default "") | default {})
        # a call with NO recorded result is the round a run died in — a timeout, a Ctrl-C, an
        # expired token. it is marked as an error rather than as a success by omission: the
        # trace exists to say what happened, and "we never learned how this call went" is not
        # the same claim as "it worked".
        let has_res = (($res | describe) | str starts-with "record") and (($res | columns | is-not-empty))
        {
          name: ($c.name? | default "?")
          input: ($c.input? | default {})
          result: (
            if $has_res { ($res | get --optional preview | default "") }
            else { "(no result recorded — the run ended before this call returned)" }
          )
          is_error: (if $has_res { not ($res | get --optional ok | default true) } else { true })
          ms: ($res | get --optional ms | default null)
          mode: ($c | get --optional mode | default ($res | get --optional mode | default ""))
        }
      })
    let folds = ($e | where kind == "fold" and round == $n)
    $rounds = ($rounds | append {
      n: $n
      text: ($re | get --optional text | default "")
      tools: $tools
      folds: $folds
      ms: ($re | get --optional ms | default null)
      stop_reason: ($re | get --optional stop_reason | default "")
    })
  }

  {
    title: "Agent Trace"
    task: ($start | get --optional task | default "")
    events: ($path | into string)
    stats: {
      rounds: ($rounds | length)
      tool_calls: ($calls | length)
      last_input_tokens: ($e | where kind == "round.end" | last | get --optional input_tokens | default "")
      stop_reason: ($e | where kind == "round.end" | last | get --optional stop_reason | default "")
      ms: ((since-epoch ($e | last | get ts)) - (since-epoch ($e | first | get ts)))
    }
    rounds: $rounds
  }
}

# the stream's own timeline, for a person reading a run after the fact.
#
# written with `get --optional` and if/else rather than `match`: an arm of the form
# `"x" => ($a? | …) + " " + ($b? | …)` does NOT parse — the arm's expression reader stops
# at the `+` and reports "expected =>, found end of input" (measured). the extra parens
# around an arm fix it, and `get --optional` here keeps the field access uniform.
export def timeline [path: any]: nothing -> table {
  read $path | each {|e|
    let kind = ($e | get --optional kind | default "")
    let detail = (
      if $kind == "tool.call" {
        let arg = (($e | get --optional input | default {}) | to json -r)
        ($e | get --optional name | default "") + " " + (($arg | str substring 0..90))
      } else if $kind == "tool.result" {
        let ms = ($e | get --optional ms | default 0)
        ((if ($e | get --optional ok | default true) { "ok" } else { "FAILED" }) + $" ($ms)ms")
      } else if $kind == "round.end" {
        let i = ($e | get --optional input_tokens | default 0)
        let o = ($e | get --optional output_tokens | default 0)
        let sr = ($e | get --optional stop_reason | default "")
        $"($i) in / ($o) out, ($sr)"
      } else if $kind == "fold" {
        let w = ($e | get --optional when | default "")
        let c = ($e | get --optional count | default 0)
        let en = ($e | get --optional entry | default "")
        $"($w) ($c) messages → ($en)"
      } else if $kind == "run.start" {
        ($e | get --optional model | default "")
      } else if $kind == "run.end" {
        ($e | get --optional status | default "")
      } else {
        ($e | get --optional reason | default "")
      }
    )
    {ts: ($e | get --optional ts), kind: $kind, round: ($e | get --optional round), detail: $detail}
  }
}

# keep the store from growing without bound. a stream is worth keeping — it is the
# only record of what a run did — but not forever, and not all of them.
export def prune [--keep: int = 200, --dry-run]: nothing -> table {
  let files = (
    ls (dir) | where {|f| ($f.name | str ends-with ".jsonl") } | sort-by modified -r
  )
  let doomed = ($files | skip $keep)
  if not $dry_run { $doomed | get name | each {|p| rm -f $p } | ignore }
  $doomed | select name modified size
}
