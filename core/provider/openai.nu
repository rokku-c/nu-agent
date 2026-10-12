# openai.nu — the OpenAI chat-completions dialect (internal)
#
# the counterpart to anthropic.nu, and the reason that one is nearly empty: the
# runtime's canonical shape is Anthropic content blocks, so this file carries
# every byte of translation between the two.
#
#   canonical (what the loop speaks)        OpenAI (what the wire wants)
#   ─────────────────────────────────────   ──────────────────────────────────
#   system field on the request             a {role: "system"} message first
#   {type: text}                            message.content
#   {type: tool_use, id, name, input}       message.tool_calls[].function
#   {type: tool_result, tool_use_id}        a separate {role: "tool"} message
#   {type: image, source: {base64}}         content part {type: "image_url"}
#   {name, description, input_schema}       {type: function, function: {…}}
#
# ── why thinking blocks are dropped on the way out ──
# OpenAI has no equivalent field, and an unknown key in a message is a 400 on
# most endpoints. the Anthropic path carries thinking back verbatim because the
# server requires its signature returned; here there is nothing to return.
# reasoning_content IS read on the way in, because DeepSeek-shaped endpoints send
# it — it just does not go back out.
#
# ── the one piece of real state ──
# OpenAI streams tool calls as `delta.tool_calls[j].function.arguments`
# fragments, where j is a position in THAT array and there are no begin/end
# markers. the canonical vocabulary is indexed by content block, so the two have
# to be related by a map that survives across SSE lines. `events` therefore takes
# and returns a state record — see the note there.

# the base URL INCLUDES the version segment, the way every OpenAI SDK treats it
# (`https://api.openai.com/v1`, `http://localhost:11434/v1`). that is what makes
# a gateway work without a special case — this machine's gateway serves
# /api/openai/chat/completions, with no /v1 anywhere, and is reached by simply
# pointing OPENAI_BASE_URL at /api/openai.
const DEFAULT_URL = "https://api.openai.com/v1"
const DEFAULT_MODEL = "gpt-4o"

export def url []: nothing -> string {
  ($env.OPENAI_BASE_URL? | default $DEFAULT_URL) | str trim -r -c "/"
}

export def auth []: nothing -> string {
  let t = ($env.OPENAI_API_KEY? | default "")
  if ($t | is-empty) {
    error make { msg: "missing the OPENAI_API_KEY env var" }
  }
  $t
}

export def model []: nothing -> string {
  $env.OPENAI_MODEL? | default $DEFAULT_MODEL
}

export def headers [token: string]: nothing -> record {
  {"content-type": "application/json", "Authorization": $"Bearer ($token)"}
}

# ── canonical → openai ──

# dissolve ONE level of nesting, without ever touching the records inside.
#
# this is not `flatten`. nu's flatten recurses into records — measured:
#   [{a: 1, b: {c: 2}}] | flatten   →  [{a: 1, c: 2}]        b is gone
# and it is worse than that: whether it hoists depends on how nested the input
# already was. `[[tool] [tool]] | flatten` leaves `input_schema` intact, while
# `[tool] | flatten` destroys it — so the same expression is safe with two
# elements and silently wrong with one. here that would collapse a single
# `tool_calls` entry from an array into a bare object, which every endpoint
# rejects. (agent.nu carries the same warning for tool definitions.)
def concat [xs: list]: nothing -> list {
  $xs | reduce --fold [] {|x, acc| $acc | append $x }
}

def as-blocks [c: any]: nothing -> list {
  if $c == null { return [] }
  let d = ($c | describe)
  if ($d | str starts-with "list") or ($d | str starts-with "table") { $c } else { [] }
}

def is-blocks [c: any]: nothing -> bool {
  if $c == null { return false }
  let d = ($c | describe)
  ($d | str starts-with "list") or ($d | str starts-with "table")
}

# an image block in canonical form → an OpenAI content part.
# the canonical form is already base64 with a media type, which is exactly a
# data: URL, so this is a rewrap rather than a fetch.
#
# `b: any`, not `b: record`: a mixed block list is inferred as a narrow
# `table<type: string>`, and a row of that is not accepted where a record is
# asked for. every access below is `get --optional` for the same reason — a
# cell path like `$b.source.media_type` would fail to compile against the
# inferred type even though the data is there.
def image-part [b: any]: nothing -> record {
  let src = ($b | get --optional source | default {})
  let mt = ($src | get --optional media_type | default "image/png")
  let data = ($src | get --optional data | default "")
  {type: "image_url", image_url: {url: $"data:($mt);base64,($data)"}}
}

# a user turn → one or more messages.
#
# it can split: canonical keeps a tool_result and the text that follows it in one
# message, while OpenAI wants each tool result as its own {role: "tool"} message.
def user-messages [content: any]: nothing -> list {
  if not (is-blocks $content) {
    return [{role: "user", content: ($content | into string)}]
  }

  let results = ($content | where {|b| ($b | get --optional type) == "tool_result"})
  let parts = (
    $content
    | where {|b| ($b | get --optional type) in ["text" "image"] }
    | each {|b|
        if ($b | get --optional type) == "image" { image-part $b }         else { {type: "text", text: ($b | get --optional text | default "")} }
      }
  )

  let tool_msgs = ($results | each {|r|
      let c = ($r | get --optional content)
      {role: "tool", tool_call_id: ($r | get --optional tool_use_id | default ""), content: (if (is-blocks $c) { ($c | to json -r) } else { ($c | into string) })}
    })

  # a plain string stays a plain string, which is what every endpoint expects for
  # the common case. `first | get --optional`, never `$parts.0.text`: a mixed
  # block list types as `table<type: string>`, so the `.text` cell path does not
  # resolve even when the single row has one.
  let user_msgs = (
    if ($parts | is-empty) {
      []
    } else if (($parts | length) == 1) and (($parts | first | get --optional type) == "text") {
      [{role: "user", content: ($parts | first | get --optional text | default "")}]
    } else {
      [{role: "user", content: $parts}]
    }
  )

  $tool_msgs | append $user_msgs
}

def assistant-message [content: any]: nothing -> record {
  if not (is-blocks $content) {
    return {role: "assistant", content: ($content | into string)}
  }

  let text = (
    $content
    | where {|b| ($b | get --optional type) == "text"}
    | get --optional text
    | default []
    | str join (char nl)
  )
  let calls = (
    $content
    | where {|b| ($b | get --optional type) == "tool_use"}
    | each {|b|
        {
          id: ($b | get --optional id | default "")
          type: "function"
          function: {
            name: ($b | get --optional name | default "")
            # arguments is a JSON *string* on this wire, not an object
            arguments: (($b | get --optional input | default {}) | to json -r)
          }
        }
      }
  )

  # thinking blocks are dropped here on purpose — see the note at the top
  if ($calls | is-empty) {
    {role: "assistant", content: $text}
  } else {
    {role: "assistant", content: $text, tool_calls: $calls}
  }
}

# canonical messages + the hoisted system prompt → the wire's message list
export def messages [m: list, system: any]: nothing -> list {
  let sys = (
    if $system == null or (($system | into string) | is-empty) { [] }     else { [{role: "system", content: ($system | into string)}] }
  )
  # one level only: a turn can expand to several messages (a tool result becomes
  # its own {role: "tool"}), and the records must come out shaped exactly as
  # written — see the note on concat
  $sys | append (concat ($m | each {|msg|
      if ($msg | get --optional role) == "assistant" { [ (assistant-message ($msg | get --optional content)) ] } else { user-messages ($msg | get --optional content) }
    }))
}

export def tools [t: list]: nothing -> list {
  $t | each {|d|
    {
      type: "function"
      function: {
        name: ($d | get --optional name | default "")
        description: ($d | get --optional description | default "")
        parameters: ($d | get --optional input_schema | default {type: "object", properties: {}})
      }
    }
  }
}

export def request [req: record]: nothing -> record {
  let body = (
    {
      model: $req.model
      max_tokens: $req.max_tokens
      messages: (messages $req.messages $req.system)
    }
    | if $req.temperature == null { $in } else { insert temperature $req.temperature }
    | if ($req.tools | is-empty) { $in } else { insert tools (tools $req.tools) }
    | if ($req | get --optional stream | default false) {
        # REQUIRED, not optional: without it OpenAI omits usage from the stream
        # entirely, so the loop's last_input_tokens stays 0 and proactive folding
        # silently never fires. the symptom is a mysterious overflow on a long
        # run, not a provider error.
        insert stream true | insert stream_options {include_usage: true}
      } else { $in }
  )
  {url: $"((url))/chat/completions", headers: (headers (auth)), body: $body}
}

# ── openai → canonical ──

# this wire's finish_reason → the canonical stop_reason the loop already reads
def finish->stop [f: any]: nothing -> string {
  match $f {
    "tool_calls" => "tool_use"
    "length" => "max_tokens"
    "stop" => "end_turn"
    "content_filter" => "refusal"
    null => "unknown"
    _ => ($f | into string)
  }
}

def usage->canonical [u: any]: nothing -> record {
  if $u == null { return {} }
  {
    input_tokens: ($u | get --optional prompt_tokens | default 0)
    output_tokens: ($u | get --optional completion_tokens | default 0)
  }
}

# a tool call's `arguments` is a JSON string; a malformed one must not take the
# whole response down
def parse-args [s: any]: nothing -> record {
  if $s == null or (($s | into string) | str trim | is-empty) { return {} }
  try { $s | into string | from json } catch { {} }
}

def message-blocks [msg: record]: nothing -> list {
  let thinking = ($msg | get --optional reasoning_content)
  let text = ($msg | get --optional content)
  let calls = ($msg | get --optional tool_calls | default [])

  let th = (
    if $thinking == null or (($thinking | into string) | is-empty) { [] }     else { [{type: "thinking", thinking: ($thinking | into string), signature: ""}] }
  )
  # OpenAI has no signature, but the canonical thinking block carries one. an
  # empty string is the honest value, and the loop only needs the field present.
  let t = (
    if $text == null or (($text | into string) | is-empty) { [] }     else { [{type: "text", text: ($text | into string)}] }
  )
  let c = (
    $calls
    | each {|call|
        {
          type: "tool_use"
          id: ($call | get --optional id | default "")
          name: ($call | get --optional function.name | default "")
          input: (parse-args ($call | get --optional function.arguments))
        }
      }
  )
  $th | append $t | append $c
}

export def response [body: record]: nothing -> record {
  let choice = ($body | get --optional choices | default [] | first)
  if $choice == null {
    # an error body on a 200, or a shape we do not know. say so rather than
    # handing the loop an empty message it will read as "finished, nothing to say"
    error make { msg: $"no choices in the response: ($body | to json -r | str substring 0..300)" }
  }
  {
    id: ($body | get --optional id | default "")
    model: ($body | get --optional model | default "")
    role: "assistant"
    content: (message-blocks ($choice | get --optional message | default {}))
    stop_reason: (finish->stop ($choice | get --optional finish_reason))
    usage: (usage->canonical ($body | get --optional usage))
  }
}

# ── streaming ──
#
# takes and returns a state record, unlike anthropic's, because this wire has no
# content-block concept:
#
#   {started: bool, next: int, text: int|null, thinking: int|null, tools: record}
#
# `next` is the next canonical block index to hand out; `tools` maps an OpenAI
# tool_calls ARRAY position to the canonical block index it was given. the map is
# the whole reason this is stateful — fragment 2 of tool_call 0 carries no id and
# no name, only `index: 0`, so without it there is nothing to attach the
# arguments to.
#
# the state lives in the stream accumulator (see stream.nu), which is threaded
# through the same reduce. it cannot be a mutable variable: `each` closures
# cannot capture one.
export def empty-state []: nothing -> record {
  {started: false, next: 0, text: null, thinking: null, tools: {}}
}

export def events [line: string, state: record]: nothing -> record {
  # `merge`, not `default`: the caller hands in `{}` on the first line, and
  # `default` only replaces null — it would leave the record empty and every
  # field below would be a missing-column error
  let s = ((empty-state) | merge ($state | default {}))
  let none = {events: [], state: $s}

  if not ($line | str starts-with "data: ") { return $none }
  let payload = ($line | str substring 6..)
  if ($payload | str trim) == "[DONE]" { return $none }

  let ev = (try { $payload | from json } catch { return $none })

  # the first frame carries id/model; there is no message_start on this wire, so
  # one is synthesized to keep the canonical vocabulary uniform
  let opening = (
    if $s.started { [] }     else { [{type: "message_start", id: ($ev | get --optional id), model: ($ev | get --optional model), usage: {}}] }
  )
  mut cur = ($s | upsert started true)
  mut out = $opening

  # a usage-bearing frame has an EMPTY choices array — which is exactly why
  # include_usage has to be sent, and why this must not treat it as malformed
  let usage = ($ev | get --optional usage)
  let choice = ($ev | get --optional choices | default [] | first)

  if $choice == null {
    if $usage != null {
      $out = ($out | append {type: "message_delta", stop_reason: null, usage: (usage->canonical $usage)})
    }
    return {events: $out, state: $cur}
  }

  let delta = ($choice | get --optional delta | default {})

  # ── text ──
  let piece = ($delta | get --optional content)
  if $piece != null and (($piece | into string) | is-not-empty) {
    if $cur.text == null {
      $out = ($out | append {type: "block_start", index: $cur.next, kind: "text", id: "", name: ""})
      $cur = ($cur | upsert text $cur.next | upsert next ($cur.next + 1))
    }
    $out = ($out | append {type: "text_delta", index: $cur.text, text: ($piece | into string)})
  }

  # ── reasoning (DeepSeek-shaped endpoints) ──
  let r = ($delta | get --optional reasoning_content)
  if $r != null and (($r | into string) | is-not-empty) {
    if $cur.thinking == null {
      $out = ($out | append {type: "block_start", index: $cur.next, kind: "thinking", id: "", name: ""})
      $cur = ($cur | upsert thinking $cur.next | upsert next ($cur.next + 1))
    }
    $out = ($out | append {type: "thinking_delta", index: $cur.thinking, text: ($r | into string)})
  }

  # ── tool calls ──
  let calls = ($delta | get --optional tool_calls | default [])
  for call in $calls {
    let j = ($call | get --optional index | default 0)
    let key = ($j | into string)
    let known = (($cur.tools | columns) | any {|c| $c == $key })

    if not $known {
      $out = ($out | append {
        type: "block_start"
        index: $cur.next
        kind: "tool_use"
        id: ($call | get --optional id | default "")
        name: ($call | get --optional function.name | default "")
      })
      $cur = ($cur | upsert tools ($cur.tools | insert $key $cur.next) | upsert next ($cur.next + 1))
    }

    let args = ($call | get --optional function.arguments)
    if $args != null and (($args | into string) | is-not-empty) {
      let target = ($cur.tools | get $key)
      $out = ($out | append {type: "tool_input_delta", index: $target, json: ($args | into string)})
    }
  }

  # ── the end ──
  let finish = ($choice | get --optional finish_reason)
  if $finish != null {
    # this wire has no block_stop either, so every open block is closed here.
    # the loop parses a tool_use block's accumulated JSON at block_stop, so
    # skipping this would hand the model a raw string where it expects a record.
    for i in 0..<$cur.next {
      $out = ($out | append {type: "block_stop", index: $i})
    }
    $out = ($out | append {type: "message_delta", stop_reason: (finish->stop $finish), usage: (usage->canonical $usage)})
    $out = ($out | append {type: "message_stop"})
  }

  {events: $out, state: $cur}
}
