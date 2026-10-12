# anthropic.nu — the Anthropic Messages API dialect (internal)
#
# ── why this file is nearly empty ──
# Anthropic's content-block shape IS the runtime's canonical form: the loop, the
# context folder, `expose`, `mcp` and `trace` all speak it. So this dialect only
# builds a request and renames SSE event types — it translates nothing.
#
# that asymmetry is deliberate. it means the working provider is a pass-through
# whose behaviour can be pinned byte-for-byte, and every byte of real translation
# is confined to one other file.

const VERSION = "2023-06-01"
const DEFAULT_URL = "https://api.anthropic.com"
const DEFAULT_MODEL = "claude-sonnet-5"

export def url []: nothing -> string {
  ($env.ANTHROPIC_BASE_URL? | default $DEFAULT_URL) | str trim -r -c "/"
}

export def auth []: nothing -> string {
  let t = ($env.ANTHROPIC_AUTH_TOKEN? | default ($env.ANTHROPIC_API_KEY? | default ""))
  if ($t | is-empty) {
    error make { msg: "missing the ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY env var" }
  }
  $t
}

export def model []: nothing -> string {
  $env.ANTHROPIC_MODEL? | default $DEFAULT_MODEL
}

# send both Authorization and x-api-key: the official API wants x-api-key, while
# gateways behind ANTHROPIC_AUTH_TOKEN usually want Bearer; giving both is easiest
export def headers [token: string]: nothing -> record {
  {
    "content-type": "application/json"
    "x-api-key": $token
    "Authorization": $"Bearer ($token)"
    "anthropic-version": $VERSION
  }
}

# build the wire request. `req` already speaks the canonical shape, so the only
# real work is hoisting `system` to the top level and dropping absent fields —
# never send null to the server.
export def request [req: record]: nothing -> record {
  let body = (
    {model: $req.model, max_tokens: $req.max_tokens, messages: $req.messages}
    | if $req.system == null { $in } else { insert system $req.system }
    | if $req.temperature == null { $in } else { insert temperature $req.temperature }
    | if ($req.tools | is-empty) { $in } else { insert tools $req.tools }
    | if ($req | get --optional stream | default false) { insert stream true } else { $in }
  )
  {url: $"((url))/v1/messages", headers: (headers (auth)), body: $body}
}

# one SSE line → zero or more normalized events.
#
# a non-data line is surfaced as a `raw` event rather than dropped: the caller
# needs it. when a gateway answers an error as plain JSON instead of SSE, those
# lines are the only evidence of what went wrong.
export def events [line: string]: nothing -> list {
  if not ($line | str starts-with "data: ") {
    if ($line | str starts-with "event: ") { return [] }
    if ($line | str trim | is-empty) { return [] }
    return [{type: "raw", line: $line}]
  }

  let payload = ($line | str substring 6..)
  if ($payload | str trim) == "[DONE]" { return [] }

  let ev = (try { $payload | from json } catch { return [] })
  let t = ($ev | get --optional type | default "")
  let i = ($ev | get --optional index | default 0)

  if $t == "message_start" {
    let m = ($ev | get --optional message | default {})
    return [{
      type: "message_start"
      id: ($m | get --optional id)
      model: ($m | get --optional model)
      stop_reason: ($m | get --optional stop_reason)
      usage: ($m | get --optional usage | default {})
    }]
  }

  if $t == "content_block_start" {
    let cb = ($ev | get --optional content_block | default {})
    return [{
      type: "block_start"
      index: $i
      kind: ($cb | get --optional type | default "text")
      id: ($cb | get --optional id | default "")
      name: ($cb | get --optional name | default "")
    }]
  }

  if $t == "content_block_delta" {
    let d = ($ev | get --optional delta | default {})
    let dt = ($d | get --optional type | default "")
    if $dt == "text_delta" { return [{type: "text_delta", index: $i, text: ($d | get --optional text | default "")}] }
    if $dt == "thinking_delta" { return [{type: "thinking_delta", index: $i, text: ($d | get --optional thinking | default "")}] }
    if $dt == "signature_delta" { return [{type: "signature_delta", index: $i, sig: ($d | get --optional signature | default "")}] }
    if $dt == "input_json_delta" { return [{type: "tool_input_delta", index: $i, json: ($d | get --optional partial_json | default "")}] }
    return []
  }

  if $t == "content_block_stop" { return [{type: "block_stop", index: $i}] }

  if $t == "message_delta" {
    let d = ($ev | get --optional delta | default {})
    return [{
      type: "message_delta"
      stop_reason: ($d | get --optional stop_reason)
      usage: ($ev | get --optional usage | default {})
    }]
  }

  if $t == "message_stop" { return [{type: "message_stop"}] }

  []
}

# a non-streaming response body is already canonical — pass it through.
export def response [body: record]: nothing -> record { $body }

# the canonical message/tool shapes are this dialect's own.
export def messages [m: list]: nothing -> list { $m }
export def tools [t: list]: nothing -> list { $t }
