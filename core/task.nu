# task.nu — delegate a subtask to a nested agent run
#
#   use task.nu
#   task "count the Rust files under src/ and report the total"
#   task "review src/auth.rs for error handling" --tools [read] --max-rounds 6
#
# offered to the model as the tool `task`, so a run can hand part of its work to
# a fresh context instead of carrying it in its own.
#
# ── why this is out-of-process for free ──
# a tool call already executes in a spawned `nu --config …` (see invoke-tool), so
# `task` there *is* a nested run in its own process, with its own context, its
# own API calls and its own crash boundary. nothing new is needed to get that —
# which is why this file is a wrapper rather than a loop.
#
# ── what the child sees ──
# ONLY $prompt. it never sees the parent's messages: inheriting them would defeat
# the point of delegating, and would spend the child's budget re-reading a
# conversation it does not need.
#
# ── what it inherits instead ──
# provider, model, cwd, credentials, and the parent's POLICY — the last of which
# is the one that has to be got right, see below.

use ./policy.nu
use ./session.nu

const DEFAULT_TOOLS = ["read" "calc" "nu-shell"]
const DEFAULT_MAX_DEPTH = 2

# the parent's capability set, as the loop exported it
def parent-tools []: nothing -> list<string> {
  ($env.NU_AGENT_TOOLS? | default "") | split row "," | where {|s| ($s | str trim) | is-not-empty }
}

# ── policy inheritance, the part that must not be got wrong ──
#
# a child may NARROW its parent's policy and never widen it. two mechanisms:
#
#  1. the parent's *compiled rules* are passed down in NU_AGENT_POLICY, which
#     policy.rules prefers over any file. passing the rules rather than a path is
#     the point: a child handed a path could point NU_POLICY_FILE at an empty
#     file and escape. what a child cannot do is escape through the tool
#     interface, which is what this defends.
#  2. the merged decision takes the most restrictive of the two, so a child that
#     adds its own rules can only add restrictions.
def compile-policy []: nothing -> any {
  let r = (policy rules)
  if (($r.rules | length) == 0) and (($r | get --optional default | default "allow") == "allow") {
    # nothing to inherit — do not inject an empty ruleset, which would shadow a
    # policy file the child is legitimately entitled to read
    return null
  }
  $r | reject --optional source | to json -r
}

def depth []: nothing -> int {
  ($env.NU_AGENT_DEPTH? | default "0") | into int
}

export def main [
  prompt: string                  # the subtask. be specific — the child has no other context.
  --system (-s): string           # REPLACES the inherited system prompt
  --tools: list<string>           # module names to expose; default is a read-only preset
  --model (-m): string
  --provider (-p): string
  --max-rounds (-r): int = 12
  --max-tokens (-t): int = 4096
  --temperature (-T): float
  --context-budget: int
  --max-output: int = 4000        # cap on the text handed back to the parent
  --max-depth: int = $DEFAULT_MAX_DEPTH
  --session: string               # store the child's transcript under this id
  --json (-j)                     # return a record instead of text
]: nothing -> any {
  let d = (depth)
  if $d >= $max_depth {
    # a hard stop, reported the way the model can read it: the caller turns this
    # into an is_error tool result rather than a crash
    error make { msg: $"task: refusing to recurse past depth ($max_depth) \(this run is already at depth ($d)\). do the work directly, or raise --max-depth if you really mean to go deeper." }
  }

  # ── the child may only narrow ──
  let allowed = (parent-tools)
  let requested = ($tools | default $DEFAULT_TOOLS)
  if ($allowed | is-not-empty) {
    let rogue = ($requested | where {|t| not ($t in $allowed) })
    if ($rogue | is-not-empty) {
      error make { msg: $"task: refusing to give the subagent tool\(s\) this run does not have: ($rogue | str join ', '). available: ($allowed | str join ', '). a subagent may narrow the parent's capabilities, never widen them." }
    }
  } else if ($env.NU_AGENT_TOOLS? | default "") == "" {
    # no parent set was exported (task called directly rather than as a tool) —
    # the preset stands on its own
  }

  # ── hand the policy down ──
  let inherited = (compile-policy)
  if $inherited != null { $env.NU_AGENT_POLICY = $inherited }
  $env.NU_AGENT_DEPTH = (($d + 1) | into string)

  # ── the system prompt ──
  # a short preamble, NOT the parent's prompt. inheriting it would re-inject the
  # parent's whole frame and spend the child's budget on instructions about a
  # conversation it cannot see.
  let sys = (
    if $system != null { $system }     else {
      "You are a subagent. You have been given one task by another agent and no access to its conversation. Work only from the task text below. Use your tools, then reply with your findings and nothing else — your reply is the entire result the caller receives."
    }
  )

  # ── run it ──
  # --json and NOT --stream, always. streamed text goes to stdout, and stdout is
  # the tool result — streaming here would interleave progress into the content
  # handed back to the parent's model. all diagnostics go to stderr via the loop.
  let r = (
    agent $prompt
      --tools-from $requested
      --system $sys
      --model $model
      --provider $provider
      --max-rounds $max_rounds
      --max-tokens $max_tokens
      --temperature $temperature
      --json
      --no-save
  )

  # the child's own transcript, stored as a session with lineage so the parent
  # can go and read the detail instead of having it all inlined.
  # note stdin/stdout discipline is preserved: the loop ran with --json and no
  # --stream, so $r.canonical is the child's real history.
  let child_rec = (
    session record-of --id $session --status ($r.status | default "done") --prompt $prompt --messages $r.canonical --provider ($provider | default "") --model ($model | default "") --system $sys --tools-from $requested --budget {
      context_budget: ($context_budget | default 0), keep_recent: 0
      max_tokens: $max_tokens, max_output: $max_output, max_rounds: $max_rounds
    } --counters {
      rounds: ($r.rounds | default 0), tool_calls: ($r.tool_calls | default 0)
      last_input_tokens: ($r.last_input_tokens | default 0), stop_reason: ($r.stop_reason | default "")
    } --context-entries ($r.context_entries | default []) --parent (session-parent) --depth ($d + 1)
  )
  let child_id = ($child_rec | session store)

  if $json { return {text: ($r.text | default ""), session: $child_id, rounds: ($r.rounds | default 0), tool_calls: ($r.tool_calls | default 0), last_input_tokens: ($r.last_input_tokens | default 0)} }

  # ── what the parent gets ──
  # the text, clamped, plus a footer. the footer is what lets the parent's model
  # self-limit: without it delegation looks free, and it is not.
  let text = ($r.text | default "")
  let clamped = (
    if ($text | str length) > $max_output {
      $"($text | str substring 0..$max_output)\n...\(subagent output truncated, was ($text | str length) chars\)"
    } else { $text }
  )
  # the footer is what lets the parent's model self-limit: without it delegation
  # looks free, and it is not. it names the stored transcript rather than
  # prescribing a command, because whether the caller can reach `session` depends
  # on what it was lent (an MCP client is not offered it — see the allowlist in
  # mcp-server.nu — but reaches it through nu-shell).
  let footer = $"[subagent ($child_id) · ($r.rounds | default 0) rounds · ($r.tool_calls | default 0) tool calls · ($r.last_input_tokens | default 0) input tokens · full transcript stored as session ($child_id)]"
  $"($clamped)\n\n($footer)"
}

def session-parent []: nothing -> any {
  $env.NU_AGENT_SESSION? | default null
}
