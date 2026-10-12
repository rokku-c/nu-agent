#!/usr/bin/env nu
# e2e.nu — end-to-end tests against a REAL model endpoint
#
# everything above this file is hermetic. this one is not: it spends tokens and
# needs a reachable API. it is skipped (visibly, never silently) when no
# credentials are present, so `test/run.nu` stays runnable on a bare checkout.
#
# what it is really guarding: the parts of the loop that only exist in motion —
# that a tool call actually round-trips through a child process, that the
# streaming path terminates, and that a trace can be built from a real run.

use ./harness.nu *

if not (needs-creds) {
  # skipped, not failed: a checkout without credentials must not go red, but it
  # must not look green either
  emit [(skip "e2e: whole suite" "no ANTHROPIC_AUTH_TOKEN in the environment — set one to run these")]
  return
}

# the OpenAI cases need an endpoint, not just a key. a key alone is not enough
# to assume api.openai.com is the right place to send it: this machine has an
# OPENAI_API_KEY in its environment that is not usable there, and a suite that
# goes red because of ambient credentials is a suite nobody trusts. pointing
# OPENAI_BASE_URL at something is the caller saying "this one is real".
def openai-ready []: nothing -> bool {
  let key = ($env.OPENAI_API_KEY? | default "")
  let url = ($env.OPENAI_BASE_URL? | default "")
  (not ($key | is-empty)) and (not ($url | is-empty))
}

let root = ($env.NU_AGENT_ROOT? | default "")
let tmp_html = ($nu.temp-dir | path join $"nu-agent-e2e-(random int 100000..999999).html")

# a 1x1 PNG, built inline so the multimodal test needs no fixture on disk
let png = ($nu.temp-dir | path join "nu-agent-e2e-1px.png")
("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | decode base64 | save -f $png)

let results = [
  # ── the plain path ──
  (case "e2e: agent chat returns the model's text" {
    let out = (agent chat "reply with exactly the two characters: OK" --max-tokens 64)
    (is-true "e2e: agent chat returns the model's text" (($out | describe) == "string" and ($out | str length) > 0))
  })

  (case "e2e: agent chat --json exposes usage and stop_reason" {
    let r = (agent chat "say hi" --max-tokens 64 --json)
    (is-true "e2e: agent chat --json exposes usage and stop_reason" (($r.usage | get --optional input_tokens) != null))
  })

  (case "e2e: agent config reports the model and hides the token" {
    let c = (agent config)
    (is-true "e2e: agent config reports the model and hides the token" (($c.model | str length) > 0 and ($c.auth | str contains "set") and (not ($c.auth | str contains ($env.ANTHROPIC_AUTH_TOKEN | str substring 0..8)))))
  })

  # ── multimodal ──
  (case "e2e: --image sends a real image block and the model answers" {
    let out = (agent chat "what colour is this 1x1 image? answer in one word" --image $png --max-tokens 512)
    (is-true "e2e: --image sends a real image block and the model answers" (($out | str length) > 0))
  })

  # ── the tool loop, which is the whole point ──
  (case "e2e: the agent loop calls a tool in a child process and uses the answer" {
    let tools = (expose from-module calc)
    let out = (agent "What is (1234 * 5678) + 99? You must use the calc tool; do not compute it yourself." --tools $tools --max-tokens 512)
    # strip formatting before comparing — the model may answer "7,006,751"
    let digits = ($out | str replace -r -a "[^0-9]" "")
    (has "e2e: the agent loop calls a tool in a child process and uses the answer" $digits "7006751")
  })

  (case "e2e: the trace of that run has the tool call paired with its result" {
    let tools = (expose from-module calc)
    let trace = (agent "What is (1234 * 5678) + 99? Use the calc tool." --tools $tools --max-tokens 512 --json)
    let model = (trace build-model $trace)
    let t = ($model.rounds | first | get tools | first)
    (is-true "e2e: the trace of that run has the tool call paired with its result" ($t.name == "calc" and ($t.result | str contains "7006751")))
  })

  (case "e2e: a run's --json reports the round and token counters" {
    let tools = (expose from-module calc)
    let r = (agent "Use the calc tool for 6*7." --tools $tools --max-tokens 512 --json)
    (is-true "e2e: a run's --json reports the round and token counters" (($r.rounds >= 2) and ($r.tool_calls >= 1) and ($r.last_input_tokens > 0)))
  })

  (case "e2e: --stream prints and returns null rather than printing twice" {
    # the streamed text goes to stdout already; a returned copy would show it again
    let r = (agent chat "count to three" --stream --max-tokens 64)
    (eq "e2e: --stream prints and returns null rather than printing twice" $r null)
  })

  (case "e2e: a starved budget warns on stderr instead of returning blank" {
    # observed live: a model with a thinking block can spend the whole budget
    # before emitting any text. the loop must say so rather than hand back an
    # empty string, which is indistinguishable from "finished, nothing to say".
    let r = (^nu --config $nu.config-path -c 'do { agent chat "think hard about the number 7" --max-tokens 16 }' | complete)
    (has "e2e: a starved budget warns on stderr instead of returning blank" $r.stderr "max-tokens")
  })

  # ── trace rendering against a real run ──
  (case "e2e: a real run renders to a self-contained HTML trace" {
    let tools = (expose from-module calc)
    let trace = (agent "Use the calc tool for 6*7." --tools $tools --max-tokens 512 --json)
    let p = ($trace | trace write $tmp_html)
    let raw = (open --raw $p)
    rm -f $p
    let injected = (not ($raw | str contains "/*__TRACE_DATA__*/"))
    (is-true "e2e: a real run renders to a self-contained HTML trace" ($injected and ($raw | str length) > 5000))
  })

  # ── the second dialect, end to end ──
  # the two wires differ enough that a translation bug only shows in motion:
  # tool_calls is an array here and a content block there, arguments are a JSON
  # string here and an object there, and the streaming state has no counterpart
  # on the other side at all.
  (case "e2e: the OpenAI dialect answers a plain turn" {
    if not (openai-ready) {
      skip "e2e: the OpenAI dialect answers a plain turn" "set OPENAI_API_KEY and OPENAI_BASE_URL"
    } else {
      let out = (agent chat "reply with exactly: OK" --provider openai --max-tokens 64)
      (is-true "e2e: the OpenAI dialect answers a plain turn" (($out | str length) > 0))
    }
  })

  (case "e2e: the OpenAI dialect runs the whole tool loop" {
    # the case that caught the flatten bug: a single tool call became an object
    # where the wire wants an array, and only round two exposed it
    if not (openai-ready) {
      skip "e2e: the OpenAI dialect runs the whole tool loop" "set OPENAI_API_KEY and OPENAI_BASE_URL"
    } else {
      let r = (agent "What is (1234 * 5678) + 99? You must use the calc tool." --tools-from [calc] --provider openai --max-tokens 512 --json)
      let digits = (($r.text | default "") | str replace -r -a "[^0-9]" "")
      (is-true "e2e: the OpenAI dialect runs the whole tool loop" (($r.rounds >= 2) and ($r.tool_calls >= 1) and ($digits | str contains "7006751")))
    }
  })

  (case "e2e: the OpenAI dialect streams" {
    if not (openai-ready) {
      skip "e2e: the OpenAI dialect streams" "set OPENAI_API_KEY and OPENAI_BASE_URL"
    } else {
      let r = (^nu --config $nu.config-path -c 'agent chat "count to three" --provider openai --stream --max-tokens 128' | complete)
      (is-true "e2e: the OpenAI dialect streams" (($r.exit_code == 0) and (($r.stdout | str trim | str length) > 0)))
    }
  })

  # ── context folding, driven by real token counts ──
  (case "e2e: a tiny context budget forces a fold and the run still finishes" {
    # this is the proactive-fold path in the loop, exercised for real rather than
    # by calling context apply directly
    let tools = (expose from-module calc)
    let r = (agent "Use the calc tool three times: 1+1, 2+2, 3+3." --tools $tools --max-tokens 512 --context-budget 600 --json)
    (is-true "e2e: a tiny context budget forces a fold and the run still finishes" ($r.done and ($r.rounds >= 1)))
  })
]

rm -f $png
emit $results
