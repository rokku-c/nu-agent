# provider.nu — pick a dialect and dispatch to it (internal)
#
# ── the canonical shape is Anthropic's ──
# decided once, in one direction: the internal message list is Anthropic content
# blocks (assistant turns carry text / thinking / tool_use, user turns carry
# tool_result), and a tool definition is {name, description, input_schema}.
# everything in the runtime already speaks that, so a dialect only has to
# describe its own wire format at the edges rather than inventing a third shape
# that everything would then have to be rewritten around.
#
# the consequence is the useful part: `anthropic.nu` is a pass-through whose
# behaviour can be pinned exactly, and `openai.nu` carries all the translation.
#
# a dialect implements: url, auth, model, headers, request, response, events —
# and (for the two whose message shapes differ) messages and tools.

use ./provider/anthropic.nu
use ./provider/openai.nu
use ./provider/stream.nu
use ./provider/transport.nu

const KNOWN = ["anthropic" "openai"]

# which dialect to use: an explicit choice, then the environment, then inference.
# inference is deliberately conservative — it only speaks up when exactly one
# provider has credentials, rather than guessing from a model name.
export def active [explicit: any]: nothing -> string {
  if $explicit != null and ($explicit | is-not-empty) { return $explicit }

  let from_env = ($env.NU_AGENT_PROVIDER? | default "")
  if ($from_env | is-not-empty) { return $from_env }

  let has_anthropic = (not (($env.ANTHROPIC_AUTH_TOKEN? | default ($env.ANTHROPIC_API_KEY? | default "")) | is-empty))
  let has_openai = (not (($env.OPENAI_API_KEY? | default "") | is-empty))

  if $has_openai and (not $has_anthropic) { "openai" } else { "anthropic" }
}

# the dialects this build knows, for a caller that has to validate a name it
# read from somewhere (a stored session, say) rather than one it chose.
export def known []: nothing -> list<string> { $KNOWN }

def check [p: string]: nothing -> nothing {
  if not ($p in $KNOWN) {
    error make { msg: $"unknown provider: ($p). known: ($KNOWN | str join ', ')" }
  }
}

export def url [p: string]: nothing -> string {
  check $p
  if $p == "anthropic" { anthropic url } else { openai url }
}

export def auth [p: string]: nothing -> string {
  check $p
  if $p == "anthropic" { anthropic auth } else { openai auth }
}

# the model name the dialect would use when the caller names none. the
# CLI-alias stripping (`deepseek-flash[1M]`) is NOT done here — such suffixes
# leak into any provider's env var equally, so it stays provider-agnostic and
# lives in the agent.
export def model [p: string]: nothing -> string {
  check $p
  if $p == "anthropic" { anthropic model } else { openai model }
}

export def headers [p: string, token: string]: nothing -> record {
  check $p
  if $p == "anthropic" { anthropic headers $token } else { openai headers $token }
}

# canonical request -> the wire request: {url, headers, body}
export def request [p: string, req: record]: nothing -> record {
  check $p
  if $p == "anthropic" { anthropic request $req } else { openai request $req }
}

# one raw SSE line -> {events, state}. the state is the dialect's scratch across
# lines — see stream.nu for why it exists and openai.nu for who needs it.
export def events [p: string, line: string, state: record]: nothing -> record {
  check $p
  if $p == "anthropic" { anthropic events $line $state } else { openai events $line $state }
}

# a non-streaming response body -> canonical
export def response [p: string, body: record]: nothing -> record {
  check $p
  if $p == "anthropic" { anthropic response $body } else { openai response $body }
}

# ── execution ──
# the dialect describes the wire; this decides what to do with it. both live
# here rather than in the agent so that transport stays internal to this layer —
# the loop asks for a message, not for an HTTP call.

# send a canonical request, return a canonical response.
export def send [p: string, req: record, timeout: duration]: nothing -> record {
  let wire = (request $p $req)
  let resp = (transport post $wire.url $wire.headers $wire.body $timeout)

  if $resp.status != 200 {
    let detail = ($resp.body | get --optional error.message | default ($resp.body | to json -r))
    error make { msg: $"API returned ($resp.status): ($detail)" }
  }

  response $p $resp.body
}

# send a canonical request as a stream, return the assembled canonical response.
#
# `md_step` / `md_flush` and `on` are injected rather than imported: markdown
# rendering is the agent's concern, and this layer should not have to know it
# exists in order to relay deltas.
export def send-stream [
  p: string
  req: record
  timeout: duration
  show_thinking: bool
  render: bool
  on: bool
  md_step: closure
  md_flush: closure
]: nothing -> record {
  let wire = (request $p $req)

  let a = (
    transport stream $wire.url $wire.headers $wire.body $timeout (stream seed) {|line, acc|
      stream step-line $line $acc {|l, st| events $p $l $st } $show_thinking $render $on $md_step $md_flush
    }
  )

  # no block parsed out of the stream means this was not SSE — almost certainly a
  # plain error body, which the dialect surfaced as `raw` events precisely so it
  # could be reported here rather than swallowed
  if ($a.blocks | is-empty) and ($a.stop_reason == null) {
    let hint = ($a.other | str join " " | str trim)
    let shown = (if ($hint | str length) > 500 { $hint | str substring 0..500 } else { $hint })
    error make { msg: $"streaming request failed\\(no SSE received\\): ($shown)" }
  }

  stream assemble $a
}
