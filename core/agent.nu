# agent.nu — the model client and the agent loop
#
#   agent chat  "explain nushell in one sentence"
#   agent chat  "what is in this screenshot?" --image shot.png     # multimodal
#   agent chat  "write a quicksort" --system "you are a senior engineer" --max-tokens 4096
#   agent chat  "hi" --json | get usage
#   agent config
#
# the loop — model wants tools, they run, results go back, until it stops wanting them:
#   let tools = (expose from-module calc)
#   agent "what is (1234 * 5678) + 99? use the calc tool" --tools $tools
#
# this file is the whole runtime: the request path, the streaming state machine,
# the tool executor, the context folding, MCP attachment and SKILL.md mounting.
# everything else in core/ is a piece it drives.
#
# ── why it is not called `llm` ──
# it never was LLM-only: `--image` sends real image blocks and the conversation
# shape carries thinking and tool_use blocks. `agent` names the thing you are
# doing rather than the model class you happen to be talking to.
#
# all config comes from env vars, nothing is written to disk:
#   ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY   auth token
#   ANTHROPIC_BASE_URL                         gateway url, official one by default
#   ANTHROPIC_MODEL                            default model

const DEFAULT_MAX_OUTPUT = 8000
# measured: models behind this gateway have a 1048576 token window; ~15% headroom left by default
const DEFAULT_CONTEXT_BUDGET = 890_000

use ./context.nu
use ./markdown.nu
use ./style.nu
use ./mcp.nu
use ./policy.nu
use ./provider.nu
use ../tools/image.nu

# strip Claude Code style context markers (e.g. "deepseek-flash[1M]").
# such suffixes are only CLI-internal aliases; sending them to the API as-is 404s.
#
# this stays provider-agnostic on purpose: the alias is a CLI convention that
# leaks into whichever model env var is set, so it is not a dialect's business.
def strip-alias [m: string]: nothing -> string {
  $m | str replace -r '\s*\[[^\]]*\]\s*$' '' | str trim
}

# the resolved dialect: an explicit --provider, else $env.NU_AGENT_PROVIDER, else
# inferred from which credentials exist.
def dialect [explicit: any]: nothing -> string {
  provider active $explicit
}

def default-model [p: string]: nothing -> string {
  let m = (provider model $p)
  if ($m | is-empty) { provider model "anthropic" } else { strip-alias $m }
}

# all progress/diagnostic output goes through here.
#
# the deciding factor is **whether stderr is a TTY** (this content goes to stderr, not stdout):
#   · stderr is a terminal → render styled output, for humans
#   · stderr is captured → emit markdown as-is, for LLMs/scripts
# the latter deliberately does **no rendering** -- the capturer is usually an LLM or a
# script, and structured `##` / `-` beats markup-stripped plain text by a lot.
def vprint [md: string]: nothing -> nothing {
  if (is-terminal --stderr) {
    print -e ($md | markdown render --force)
  } else {
    print -e $md
  }
}

# An image path -> an Anthropic image content block.
# The file goes through image as-supported: png/jpeg/gif/webp are taken as-is,
# anything else (heic, tiff, bmp …) is converted with sips first.
def image-block [p: path]: nothing -> record {
  let f = (image as-supported $p)
  let ext = ($f | path parse | get extension | str lowercase)
  let mt = (
    match $ext {
      "png" => "image/png"
      "jpg" | "jpeg" => "image/jpeg"
      "gif" => "image/gif"
      "webp" => "image/webp"
      _ => "image/png"
    }
  )
  {type: "image", source: {type: "base64", media_type: $mt, data: (open --raw $f | encode base64)}}
}

# A user message's content. With no images it stays a plain string, so the
# common case sends exactly what it did before; with images it becomes a block
# list with the pictures ahead of the text.
def user-content [text: string, images: any]: nothing -> any {
  let imgs = ($images | default [])
  if ($imgs | is-empty) { return $text }
  ($imgs | each {|p| image-block $p }) | append [{type: "text", text: $text}]
}

# the two ways to get a message back. both return the same canonical shape, so
# nothing downstream has to know which one ran, and both are thin: the dialect,
# the transport and the status handling all live behind `provider`.
def api-call [
  p: string
  messages: list
  tools: any
  system: any
  model: string
  max_tokens: int
  temperature: any
  timeout: duration
]: nothing -> record {
  provider send $p {
    model: $model, max_tokens: $max_tokens, messages: $messages
    system: $system, temperature: $temperature, tools: $tools, stream: false
  } $timeout
}

# streaming. the accumulator and SSE handling live in core/provider/stream.nu;
# the markdown renderer is passed in, because it is this file's dependency.
# why a stream needs curl at all is explained in transport.nu.
def stream-api-call [
  p: string
  messages: list
  tools: any
  system: any
  model: string
  max_tokens: int
  temperature: any
  timeout: duration
  show_thinking: bool
  render: bool
]: nothing -> record {
  provider send-stream $p {
    model: $model, max_tokens: $max_tokens, messages: $messages
    system: $system, temperature: $temperature, tools: $tools, stream: true
  } $timeout $show_thinking $render (style enabled) {|st, c, o| markdown stream-step $st $c $o } {|st, o| markdown stream-flush $st $o }
}

# consult the policy for one tool call and, if it is not allowed, raise.
#
# raising rather than returning is the whole design: the caller sits inside the
# tool executor's try/catch, and a raised error becomes an ordinary is_error
# tool_result the model can read and correct itself from. `error make`'s msg is
# the only field a catch can read (measured), so the messages are self-contained.
#
# an `ask` is resolved once here — `policy defer` writes a pending record, so
# calling it to inspect the outcome would record the same call twice.
def gate [tool: string, command: string, input: any]: nothing -> nothing {
  let v = (policy check {tool: $tool, command: $command, input: $input})
  if $v.decision == "allow" { return }
  let d = (if $v.decision == "ask" { policy defer $v } else { $v })
  if $d.decision == "deny" { error make { msg: (policy refuse-message $d) } }
  if $d.decision == "defer" { error make { msg: (policy defer-message $d) } }
}

# pick blocks of a given type out of content
def blocks-of [body: record, kind: string]: nothing -> list {
  ($body | get --optional content | default []) | where type == $kind
}

def text-of [body: record]: nothing -> string {
  (blocks-of $body "text") | get --optional text | default [] | str join (char nl)
}

# ── tool calls ──

# reverse a tool name back into a nu command name.
# tool generation swapped spaces for underscores (agent chat → agent_chat); try a few spellings back here.
def resolve-command [tool_name: string]: nothing -> string {
  let cands = ([
    $tool_name
    ($tool_name | str replace -a '_' ' ')
    ($tool_name | str replace -a '_' '-')
  ] | uniq)
  let hits = ($cands | where {|c| (scope commands | where name == $c | is-not-empty) })
  if ($hits | is-empty) {
    error make { msg: $"cannot reverse tool name ($tool_name) into a nu command; name it explicitly with --map" }
  }
  $hits.0
}

# reassemble JSON arguments into a nu command line according to the signature.
# the signature lookup is mandatory: positional args and --flags are spelled completely
# differently, and guessing gets it wrong.
def build-script [cmd: string, input: record]: nothing -> string {
  let found = (scope commands | where name == $cmd)
  if ($found | is-empty) {
    error make { msg: $"command does not exist: ($cmd)" }
  }

  let sig = (
    $found | first | get signatures
    | values | flatten
    | where {|p| ($p | get --optional parameter_name) != null }
    | group-by parameter_name | values | each {|g| $g | first }
  )

  let parts = ($sig | each {|p|
      let raw = ($p | get --optional parameter_name)
      let kind = ($p | get --optional parameter_type | default "")
      let snake = ($raw | str replace -a '-' '_')
      # param names may come from a --snake generated tool; accept both spellings
      let v = ($input | get --optional $raw | default ($input | get --optional $snake))

      if $kind == "switch" {
        if $v == true { [$" --($raw)"] } else { [] }
      } else if $v == null {
        # skip when not passed; if a required positional is missing let nu raise the error, it gets fed back to the model
        []
      } else if $kind == "rest" {
        # the leading space can't be dropped: the command name and the Nth argument must be
        # separated, otherwise you build things like agent chat"x" and nu runs `agent` as an external command
        $v | each {|e| $" ($e | to nuon)" }
      } else if $kind == "positional" {
        [$" ($v | to nuon)"]
      } else {
        [$" --($raw) ($v | to nuon)"]
      }
    } | flatten)

  $"($cmd)($parts | str join '')"
}

# execute one tool_use block, return a tool_result block.
# exported for reuse: the MCP server (mcp-server.nu) executes tool calls with the same
# machinery, so "reverse the name + look up the signature + build the command line +
# run a subprocess" doesn't have to be copied a second time.
export def "invoke-tool" [
  call: record
  map: any
  max_output: int
  timeout: duration
  verbose: bool
]: nothing -> record {
  let tool_name = ($call | get --optional name | default "")
  let input = ($call | get --optional input | default {})

  # any exception during tool execution (command not found, args not assemblable) must turn
  # into an is_error result fed back to the model, instead of tearing down the whole loop --
  # the model can correct itself once it sees the error
  let outcome = (try {
      let target = (
        if $map != null and (($map | columns) | any {|c| $c == $tool_name }) {
          $map | get $tool_name
        } else {
          resolve-command $tool_name
        }
      )

      # run in a subprocess rather than in place: nu has no builtin for calling a command
      # dynamically by name, and the isolation keeps a tool failure from tearing down the
      # whole session.
      # --config is required, otherwise the subprocess doesn't load config.nu and can't find module commands.
      let script = (build-script $target $input)
      if $verbose { vprint $"- run: `($script)`" }

      # ── the policy gate ──
      # positioned deliberately: AFTER build-script, because `command` patterns
      # match on the assembled line and gating earlier would have nothing to
      # match; and INSIDE the try, so a denial becomes an is_error tool_result
      # rather than propagating through the loop's `each` closure and killing
      # the run.
      gate $tool_name $script $input

      # A record result is serialized to JSON before it leaves the subprocess.
      #
      # nu renders a record as a table, and a field holding a multi-line value
      # gets wrapped into its cell — so a record whose stdout is itself a table
      # arrives shredded: `| stdout | | # | name | … |` with the inner table
      # broken across rows. JSON has no such problem.
      #
      # Only records are converted. A flat table keeps whatever table.mode says
      # (markdown for a pipe), which stays the most compact form for tabular data,
      # and a plain string is left exactly as it is.
      #
      # Built by concatenation with single-quoted pieces: the tail contains $in,
      # which an interpolated string would try to expand.
      let wrapped = ('do { ' + $script + ' } | if (($in | describe) | str starts-with "record") { to json -r } else { $in }')

      let r = (^nu --config $nu.config-path -c $wrapped | complete)
      {
        ok: ($r.exit_code == 0)
        raw: (if $r.exit_code == 0 { $r.stdout } else { $"exit code ($r.exit_code): ($r.stderr)" })
      }
    } catch {|e|
      {ok: false, raw: $"tool execution failed: ($e.msg)"}
    })

  let ok = $outcome.ok
  let raw = $outcome.raw
  # str substring truncates automatically past the length, it doesn't error
  # literal parens must be written \( \) -- a bare ( is taken as an interpolation and runs a command.
  # it's especially fatal here: any tool output longer than --max-output reaches this line,
  # and getting it wrong isn't "truncation", it crashes the whole agent.
  let text = (if ($raw | str length) > $max_output {
      $"($raw | str substring 0..$max_output)\n...\(output truncated, original length ($raw | str length) chars\)"
    } else { $raw })

  {
    type: "tool_result"
    tool_use_id: ($call | get --optional id | default "")
    content: (if ($text | str trim | is-empty) { "(no output)" } else { $text })
    is_error: (not $ok)
  }
}

# single element → list, used to flatten nested forms like [[tools...] [tools...]].
#
# never use flatten: nu's flatten **recurses into records**, hoisting the subfields of a
# nested field up to the outer level and dropping the original field entirely. measured:
#   [{a: 1, b: {c: 2}}] | flatten  →  [{a: 1, c: 2}]     b is gone
# a tool definition's input_schema is exactly this kind of nested record, one flatten and it's ruined.
#
# also note: a list of records describes as table<...>, not list<...>.
def as-list [x: any]: nothing -> list {
  let d = ($x | describe)
  if (($d | str starts-with "list") or ($d | str starts-with "table")) {
    $x
  } else {
    [$x]
  }
}

# normalize the tools argument.
#
# nu builtins silently overwrite when the same flag is passed twice, so "several tools" has
# to be written as a list; but expose from-module already returns a list, so
#   --tools [(expose from-module a) (expose from-module b)]
# hands you a **list of lists**. flatten it here rather than sending a malformed structure
# to the API (the gateway only answers with an inscrutable 502 invalid request body).
def normalize-tools [raw: any]: nothing -> list {
  let v = ($raw | default [])
  if ($v | is-empty) { return [] }

  let flat = ($v | reduce --fold [] {|item, acc| $acc | append (as-list $item) })

  let notrecord = ($flat | where {|t| not (($t | describe) | str starts-with "record") })
  if ($notrecord | is-not-empty) {
    error make { msg: "tools must be a list of tool definition records. generate them with expose from-module; nesting several modules is fine (they get flattened automatically)" }
  }

  let missing = ($flat | where {|t|
      (($t | get --optional name) == null) or (($t | get --optional input_schema) == null)
    })
  if ($missing | is-not-empty) {
    error make { msg: "a tool is missing its name or input_schema field, so it isn't a valid tool definition" }
  }
  $flat
}

# ── public commands ──

# show the config currently in effect (never the token contents)
export def config [--provider (-p): string]: nothing -> record {
  let p = (dialect $provider)
  # auth is reported, not required — an unconfigured setup should be able to ask
  # what is wrong without the question itself throwing
  let t = (try { provider auth $p } catch { "" })
  {
    provider: $p
    base_url: (provider url $p)
    model: (default-model $p)
    auth: (if ($t | is-empty) { "not set" } else { $"set, ($t | str length) chars" })
  }
}

# send one message to the model, return the reply text
export def chat [
  prompt: string                  # the prompt to send
  --system (-s): string           # system prompt
  --model (-m): string            # model name, defaults to the provider's own env var
  --provider (-p): string         # anthropic (default), else $env.NU_AGENT_PROVIDER
  --policy: path                  # rules file for this run (default $nu.default-config-dir/agent-policy.json)
  --max-tokens (-t): int = 2048   # max output tokens; note that thinking blocks also spend from it
  --temperature (-T): float       # sampling temperature, server default when omitted
  --timeout: duration = 120sec    # request timeout
  --tools: list                   # tool definitions (expose output); supplying them can trigger tool_use
  --show-thinking                 # print thinking blocks to stderr
  --stream                        # print as it arrives: text→stdout, thinking→stderr
  --md                            # render the reply as markdown (with --stream, render while streaming)
  --image: list<path>             # attach images to the question (vision models only)
  --json (-j)                     # return the full response record instead of plain text
]: nothing -> any {
  if $policy != null { $env.NU_POLICY_FILE = ($policy | path expand) }

  let p = (dialect $provider)
  let model = (strip-alias ($model | default (default-model $p)))
  let tools = (normalize-tools $tools)


  if $stream and $json {
    error make { msg: "--stream and --json are mutually exclusive: streaming already printed the content, returning a record too would duplicate it" }
  }

  let body = (
    if $stream {
      stream-api-call $p [{role: "user", content: (user-content $prompt $image)}] $tools $system $model $max_tokens $temperature $timeout $show_thinking $md
    } else {
      api-call $p [{role: "user", content: (user-content $prompt $image)}] $tools $system $model $max_tokens $temperature $timeout
    }
  )

  let thinking = (blocks-of $body "thinking" | get --optional thinking | default [] | str join (char nl))
  let calls = (blocks-of $body "tool_use")
  let text = (text-of $body)
  let stop = ($body.stop_reason? | default "unknown")

  if $show_thinking and (not $stream) and ($thinking | is-not-empty) {
    vprint $"
### thinking

($thinking | lines | each {|l| $"> ($l)" } | str join (char nl))"
  }

  if $stream {
    # the text was already printed live, so this only wraps up. return null --
    # returning a text copy too would make the terminal show it a second time.
    if ($text | is-not-empty) { print "" }
    if ($text | is-empty) {
      if ($calls | is-not-empty) {
        print -e $"the model made ($calls | length) tool calls with no text reply"
      } else {
        print -e $"warning: the stream ended without receiving anything, stop_reason=($stop); try a larger --max-tokens"
      }
    }
    return null
  }

  # the model may burn the whole budget on thinking, or decide to call tools without
  # returning text -- both have to be spelled out, otherwise the user just sees blank
  if ($text | is-empty) {
    if ($calls | is-not-empty) {
      print -e $"the model made ($calls | length) tool calls with no text reply; use --json for details"
    } else {
      print -e $"warning: no text block in the response, stop_reason=($stop); try a larger --max-tokens"
    }
  } else if $stop == "max_tokens" {
    print -e "warning: truncated by max_tokens, the reply may be incomplete"
  }

  if $json { $body } else if $md { $text | markdown render } else { $text }
}

# decide whether an API error is a "context overflow".
#
# measured: this gateway's error looks like this -- note it's HTTP **502**, not 400, and
# error.message wraps another layer of JSON string:
#   {"error":{"message":"{\"error\":{\"message\":\"This model's maximum
#    context length is 1048576 tokens. However, you requested 1160047
#    tokens ...\"}}","type":"api_error"},"type":"error"}
#
# so this only does substring matching and doesn't try to parse that nested structure.
def is-overflow [err: string]: nothing -> bool {
  let pats = [
    "maximum context length"
    "context_length_exceeded"
    "context length"
    "context limit"
    "prompt is too long"
    "too many tokens"
    "reduce the length"
    "tokens in the messages"
  ]
  let low = ($err | str lowercase)
  $pats | any {|p| $low | str contains ($p | str lowercase) }
}

# pull the model window size out of an overflow error. returns null when it can't be found.
# the raw error reads like: ... maximum context length is 1048576 tokens. However,
# only the real window makes "how far to fold" computable -- deriving it from
# --context-budget is wrong, that value may be set higher than the window, so the fold is
# still too small and the retry fails just the same.
def parse-window [err: string]: nothing -> any {
  let hit = ($err | parse --regex "maximum context length is (?<n>[0-9]+) tokens" | get -o n.0)
  if $hit == null { null } else { $hit | into int }
}

# handle one context overflow: fold away part of it, return messages that can be retried.
#
# split into its own command for two reasons:
#  1. clearer structure -- that nested block in the agent loop is too heavy
#  2. it can be tested on its own. really triggering an overflow means blowing past a 1M
#     context, burning two million tokens in one go, and waiting for the model to
#     voluntarily call an output-size tool is both expensive and flaky. with this entry
#     point the whole chain can be verified directly from a real error string.
#
# returns {ok: true, messages, entry, record, window, tighter}
# or      {ok: false, reason, entry, window} (nothing left to fold)
export def "handle-overflow" [
  messages: list      # current messages
  err: string         # raw error text returned by the API
  --budget: int = $DEFAULT_CONTEXT_BUDGET
]: nothing -> record {
  # the fold target prefers the "real window written in the error". deriving from --budget is
  # wrong: that value may be higher than the window, so the fold is still too small and the retry fails anyway.
  let window = (parse-window $err)
  let tighter = (
    if $window == null {
      ((($budget * 3) / 4) | math floor)
    } else {
      # fold to 60% of the window, leaving headroom for this round's new content
      (($window * 6) / 10 | math floor)
    }
  )

  # keep-recent 0: in an emergency we have to be able to fold the big recent blocks,
  # otherwise "the last 2 messages" protects exactly the bulkiest tool result (been there).
  # item 0 (the task) is protected by apply's own default.
  let f = (
    $messages
    | context apply --budget $tighter --keep-recent 0 --note "fold after overflow"
  )

  if not $f.changed {
    return {
      ok: false
      window: $window
      entry: $f.entry
      reason: (
        $"context overflow\(window ($window) tokens\), but there is nothing left to fold. "
        + "the remaining bulk sits in protected places\(the original task, or a single oversized tool result\). "
        + "suggestion: lower --max-output to cap one tool output, or split the task into smaller steps."
      )
    }
  }

  {
    ok: true
    messages: $f.messages
    entry: $f.entry
    window: $window
    tighter: $tighter
    record: {
      when: "overflow"
      count: ($f.folded | length)
      before: $f.before_tokens
      after: $f.after_tokens
      entry: $f.entry
      window: $window
    }
  }
}

# the full agent loop: model wants tools → execute → feed results back → continue, until the model stops wanting tools
#
# rounds are **unlimited** by default: truncating on a round cap confuses "the task really
# needs more rounds" with "the context blew up". context is context's job --
# each round carries the real usage.input_tokens, so it can fold proactively as the budget
# nears, and fold again on overflow with a tighter budget before retrying. everything is
# written to disk and can be shown back at any time.
export def main [
  prompt: string                  # task description
  --tools: list                   # tool definitions, usually expose from-module output
  --system (-s): string           # system prompt
  --model (-m): string
  --provider (-p): string         # anthropic (default), else $env.NU_AGENT_PROVIDER
  --policy: path                  # rules file for this run (default $nu.default-config-dir/agent-policy.json)
  --max-tokens (-t): int = 4096
  --temperature (-T): float
  --timeout: duration = 120sec
  --max-rounds (-r): int          # omitted = unlimited rounds, runs until the model wraps up itself
  --max-output: int = $DEFAULT_MAX_OUTPUT  # truncation length for one tool output
  --map: record                   # manually map tool name → nu command name, overriding the automatic reverse lookup
  --json (-j)                     # return the full trace instead of the final text
  --verbose (-v)                  # print per-round progress to stderr
  --stream                        # print as it arrives: text→stdout, thinking/progress→stderr
  --show-thinking                 # also print thinking to stderr when streaming (requires --stream)
  --md                            # render the final reply as markdown (with --stream, render while streaming)
  --context-budget: int = $DEFAULT_CONTEXT_BUDGET  # fold old turns once this is exceeded
  --keep-recent: int = 4          # the most recent N messages are never folded
  --no-fold                       # turn off automatic folding (keep the full context, error out on overflow)
  --mcp: list<list<string>>       # attach MCP servers; each entry is that server's argv
  --skill: list<path>             # mount SKILL.md files explicitly; their body joins the system prompt
  --image: list<path>             # attach images to the opening question (vision models only)
]: nothing -> any {
  if $policy != null { $env.NU_POLICY_FILE = ($policy | path expand) }

  let p = (dialect $provider)
  let model = (strip-alias ($model | default (default-model $p)))
  let tools = (normalize-tools $tools)

  # ── explicitly mounted skills ──
  # Each file's body is appended to the system prompt. Frontmatter is dropped:
  # `name`/`description` exist to help a client decide *whether* to load a skill,
  # which is a decision the caller already made by passing --skill.
  let skill_text = (
    ($skill | default [])
    | each {|p|
        let f = ($p | path expand)
        if not ($f | path exists) {
          error make { msg: $"skill not found: ($f)" }
        }
        let raw = (open --raw $f)
        # strip YAML frontmatter: split on --- leaves an empty head, the
        # frontmatter, then the body. A --- inside the body only adds parts,
        # which rejoining puts back.
        let body = (
          if ($raw | str starts-with "---") {
            let parts = ($raw | split row "---")
            if ($parts | length) > 2 { $parts | skip 2 | str join "---" } else { $raw }
          } else { $raw }
        )
        $"# skill: ($f | path basename)

($body | str trim)"
      }
    | str join "

---

"
  )
  let sys = (
    if ($skill_text | is-empty) { $system }
    else if $system == null { $skill_text }
    else { $"($system)

---

($skill_text)" }
  )

  # ── attached MCP servers ──
  # Handshake each server once up front (its tools are needed to build the
  # request), and remember which server each tool came from so a tool_use can
  # be routed back. Calls themselves re-spawn the server — see mcp.
  mut mcp_map = {}
  mut mcp_tools = []
  for srv in ($mcp | default []) {
    let h = (mcp handshake $srv)
    let ts = (mcp tools $srv)
    # no parentheses in this line on purpose: a literal paren inside $"..."
    # must be escaped, and getting that wrong here silently turned the next
    # token into a command name
    print -e $"mcp server ($h.server) ($h.version) · protocol ($h.protocol) · ($ts | length) tools"
    for t in $ts {
      if ($mcp_map | columns | any {|c| $c == $t.name }) {
        print -e $"  warning: tool ($t.name) already exists, keeping the first"
      } else {
        $mcp_map = ($mcp_map | upsert $t.name $srv)
      }
    }
    $mcp_tools = ($mcp_tools | append $ts)
  }
  if ($mcp_tools | is-not-empty) {
    let nservers = ($mcp | length)
    print -e $"attached ($mcp_map | columns | length) MCP tools from ($nservers) servers"
  }
  # An each closure cannot capture a mutable variable, so freeze the routing
  # table into an immutable binding before the tool loop uses it.
  let mmap = $mcp_map
  let tools = ($tools | append $mcp_tools)

  if $stream and $json {
    error make { msg: "--stream and --json are mutually exclusive: streaming already printed the content, returning a trace too would duplicate it" }
  }

  # start from an empty list, don't write [{role: "user", content: $prompt}] --
  # that would narrow $messages' type to content: string, and appending an assistant
  # message carrying content blocks (a list) later gives type_mismatch.
  # an empty list infers as list<any>, which keeps the flexibility.
  mut messages = []
  $messages = ($messages | append {role: "user", content: (user-content $prompt $image)})
  mut done = false
  mut text = ""
  mut rounds = 0
  mut tool_calls = 0
  mut last_tokens = 0
  # estimated size of the next request. last_tokens alone isn't enough -- that's the real
  # value "before the tool results were added", and one big output can blow up the next
  # round outright. so account for it once the results are appended.
  mut est_next = 0
  mut stop_reason = "unknown"
  mut streamed = false
  mut entries = []
  mut folds = []
  mut retries = 0

  # with no cap set, a very high hard ceiling, purely to guard against a genuine runaway
  let round_cap = (if $max_rounds == null { 10000 } else { $max_rounds })

  while (not $done) and ($rounds < $round_cap) {
    # proactive folding: slim down first when the next round is estimated to blow the budget
    if (not $no_fold) and ($est_next >= $context_budget) {
      let f = ($messages | context apply --budget $context_budget --keep-recent $keep_recent --note $"proactive fold before round ($rounds + 1)")
      if $f.changed {
        $messages = $f.messages
        $entries = ($entries | append $f.entry)
        $folds = ($folds | append {
          when: "proactive", round: ($rounds + 1), count: ($f.folded | length)
          before: $f.before_tokens, after: $f.after_tokens, entry: $f.entry
        })
        vprint $"- folded ($f.folded | length) messages → entry `($f.entry)`\(estimated ($est_next) / budget ($context_budget) tokens\)"
      }
    }

    if $verbose { vprint $"
## round ($rounds + 1)
" }

    let attempt = (try {
        let b = (
          if $stream {
            stream-api-call $p $messages $tools $sys $model $max_tokens $temperature $timeout $show_thinking $md
          } else {
            api-call $p $messages $tools $sys $model $max_tokens $temperature $timeout
          }
        )
        {ok: true, body: $b}
      } catch {|e|
        {ok: false, err: ($e.msg | into string)}
      })

    if not $attempt.ok {
      # overflow: fold part of it and retry. at most 3 globally, so a pointless fold doesn't spin forever.
      if (not $no_fold) and ($retries < 3) and (is-overflow $attempt.err) {
        $retries = $retries + 1
        let h = (handle-overflow $messages $attempt.err --budget $context_budget)
        if not $h.ok {
          error make { msg: $h.reason }
        }
        if $h.window != null {
          vprint $"- window: ($h.window) tokens, fold target ($h.tighter)"
        }
        $messages = $h.messages
        $entries = ($entries | append $h.entry)
        $folds = ($folds | append ($h.record | insert round ($rounds + 1)))
        vprint $"- context overflow, folded ($h.record.count) messages → entry `($h.entry)`, retrying"
        # keep this more accurate budget after the retry too, so the next round doesn't hit the same wall
        $est_next = $h.record.after
        continue
      }
      error make { msg: $"round ($rounds + 1) failed: ($attempt.err)" }
    }

    let body = $attempt.body
    $last_tokens = ($body | get --optional usage.input_tokens | default 0)
    $est_next = $last_tokens
    $stop_reason = ($body | get --optional stop_reason | default "unknown")

    let blocks = ($body | get --optional content | default [])
    let calls = ($blocks | where type == "tool_use")
    let reply = (text-of $body)
    # this round's assistant message must be carried verbatim, thinking blocks included -- drop the signature and the server rejects it
    $messages = ($messages | append {role: "assistant", content: $blocks})
    $rounds = $rounds + 1

    if $verbose and ($last_tokens > 0) {
      vprint $"- context: ($last_tokens) tokens"
    }
    # wrap up this round's text when streaming, so the next round's progress doesn't stick to the same line
    if $stream and (($reply | str trim) | is-not-empty) {
      print ""
      $streamed = true
    }

    if ($calls | is-empty) {
      $text = $reply
      $done = true
    } else {
      if $verbose {
        let names = ($calls | get name | each {|n| $"`($n)`" } | str join ", ")
        vprint $"- requesting tools: ($names)"
      }
      let results = ($calls | each {|c|
          let tname = ($c | get --optional name | default "")
          # An MCP tool goes back to its server; anything else is a nu command.
          let r = (
            if (($mmap | columns) | any {|k| $k == $tname }) {
              # MCP tools never reach invoke-tool, so the gate is repeated here —
              # without it a policy would cover every nu-command tool and quietly
              # not cover anything reached over MCP. there is no assembled command
              # line on this path, so `command` patterns cannot match here; `tool`
              # and `path` ones still do.
              let input = ($c | get --optional input | default {})
              let id = ($c | get --optional id | default "")
              let refusal = (try { gate $tname "" $input; null } catch {|e| ($e.msg | into string) })
              if $refusal != null {
                {type: "tool_result", tool_use_id: $id, content: $refusal, is_error: true}
              } else {
                let out = (mcp call ($mmap | get $tname) $tname $input)
                {type: "tool_result", tool_use_id: $id, content: $out.text, is_error: $out.is_error}
              }
            } else {
              invoke-tool $c $map $max_output $timeout $verbose
            }
          )
          if $verbose {
            # Show a few lines rather than just the first — a one-line preview
            # hides whether a result is worth opening at all. The full result
            # lives in the trace page (trace).
            let all = ($r.content | lines)
            let head = ($all | first 5 | str join (char nl))
            # NOTE the double parens: \( escapes a literal "(", then the
            # interpolation opens — so `\(($all | length) - 5\)` would close the
            # interpolation right after `length` and print "30 - 5" literally.
            # The whole expression has to be inside one ( ).
            let more = (if ($all | length) > 5 { $"\n  ...\(((($all | length) - 5)) more lines\)" } else { "" })
            # Fence the result rather than quoting it with "> ".
            #
            # A tool result is data, not markdown prose. Prefixing every line
            # with a blockquote marker fights whatever structure the data
            # already has — a result that is itself a markdown table came out
            # as `│ | stdout | | # | name | …`, the two prefix systems layered.
            # A fenced block is markdown's "show this verbatim", so the data
            # passes through untouched and still renders as one block.
            #
            # Four backticks, so a result containing a ``` fence cannot end the
            # block early.
            vprint $"- result `($c | get --optional name | default '?')`:"
            vprint $"\n````\n($head)($more)\n````\n"
          }
          $r
        })
      $messages = ($messages | append {role: "user", content: $results})
      $tool_calls = $tool_calls + ($calls | length)
      # tool results are usually the bulk, so they must count toward the next estimate (rough: chars / 3)
      let added = (($results | to json -r | str length) / 3 | math ceil)
      $est_next = ($last_tokens + $added)
    }
  }

  if (not $done) {
    print -e $"warning: hit the round cap ($round_cap) while the model was still requesting tool calls"
  }
  # an empty reply must be spelled out, otherwise the caller can't tell "finished with
  # nothing to say" from "something broke".
  # common cause: a small --max-tokens lets thinking blocks burn the whole budget.
  # when streaming the text was already printed live, so the test becomes "did any text stream at all".
  if $stream {
    if not $streamed {
      print -e $"warning: no text reply arrived during the whole run\(stop_reason=($stop_reason)\). if that's max_tokens, try a larger --max-tokens"
    }
  } else if $done and (($text | str trim) | is-empty) {
    print -e $"warning: the model finished with no text reply\(stop_reason=($stop_reason)\). if that's max_tokens, try a larger --max-tokens; --json shows the full trace"
  }
  if (not $no_fold) and (($folds | length) > 0) {
    vprint $"- folded ($folds | length) times this run; original context: ($entries | each {|e| $"`($e)`" } | str join ', ')"
  }

  let final = {
    messages: $messages
    done: $done
    text: $text
    rounds: $rounds
    tool_calls: $tool_calls
    last_input_tokens: $last_tokens
    stop_reason: $stop_reason
    context_entries: $entries
    folds: $folds
  }

  # streaming already printed the text; returning a copy would show it twice in the terminal
  if $stream { return null }

  if $json { $final } else if $md { $final.text | markdown render } else { $final.text }
}
