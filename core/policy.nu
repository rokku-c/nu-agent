# policy.nu — a gate consulted before a tool call runs
#
#   use policy.nu
#
#   let p = (policy check {tool: "bash", command: "rm -rf /", input: {}})
#   $p.decision          # allow | deny | ask
#   policy explain {...} # why, for writing a rules file
#   policy test          # dry-run every rule against samples
#   policy pending       # tool calls deferred for a human
#   policy approve pol-… # release one
#
# ── the default is allow, and that is deliberate ──
# the existing loop runs every tool with no confirmation, and that is a feature
# other things depend on. a gate that tightens the default would silently change
# working behaviour, so policy activates only when a rules file exists or
# --policy is passed. with no rules file, `check` returns allow without reading
# anything.
#
# ── how a denial reaches the model ──
# a denial has to arrive as an ordinary tool failure, not as a crash. the loop's
# tool executor wraps everything in try/catch and turns any exception into an
# is_error tool_result the model can read and correct itself from — so a denial
# raises, and must raise **inside** that try, after the command line has been
# assembled (the assembled line is what `command` patterns match on).
#
# note (measured): `error make`'s help/labels are unreachable from a catch — only
# msg survives, and the executor reads only msg. the whole explanation,
# including advice for the model, therefore goes in the message.

use ../core/quote.nu

const DEFAULT_FILE = "agent-policy.json"

# ── glob matching ──
# nu's glob works on paths, not on arbitrary strings, so patterns are compiled to
# a regex here. only * and ? are special; everything else is literal, which keeps
# a pattern like `rm -rf *` meaning what it looks like.
def glob->regex [pat: string]: nothing -> string {
  let escaped = (
    $pat
    | str replace -a '\' '\\'
    | str replace -a '.' '\.'
    | str replace -a '+' '\+'
    | str replace -a '(' '\('
    | str replace -a ')' '\)'
    | str replace -a '[' '\['
    | str replace -a ']' '\]'
    | str replace -a '{' '\{'
    | str replace -a '}' '\}'
    | str replace -a '^' '\^'
    | str replace -a '$' '\$'
    | str replace -a '|' '\|'
  )
  $"^($escaped | str replace -a '*' '.*' | str replace -a '?' '.')$"
}

def matches [pat: string, s: string]: nothing -> bool {
  ($s | str replace -r (glob->regex $pat) "!") != $s
}

# ── rules ──

export def rules-path []: nothing -> path {
  let override = ($env.NU_POLICY_FILE? | default "")
  if ($override | is-empty) {
    $nu.default-config-dir | path join $DEFAULT_FILE
  } else {
    $override | path expand
  }
}

# the rules in effect. $env.NU_AGENT_POLICY (a compiled rules record, as JSON)
# wins over the file: a subagent is handed its parent's compiled rules, so it
# cannot escape a restriction by pointing NU_POLICY_FILE somewhere empty.
export def rules []: nothing -> record {
  let injected = ($env.NU_AGENT_POLICY? | default "")
  if ($injected | is-not-empty) {
    return ($injected | from json)
  }

  let p = (rules-path)
  if not ($p | path exists) {
    # no file means the gate is open, and says so rather than inventing a default
    return {version: 1, default: "allow", rules: [], source: "none"}
  }

  let r = (open $p)
  let missing = (["default" "rules"] | where {|k| ($r | get --optional $k) == null })
  if ($missing | is-not-empty) {
    error make { msg: $"($p) is missing required field\(s\): ($missing | str join ', '). expected {default: allow|deny|ask, rules: [...]}" }
  }
  $r | upsert source ($p | into string)
}

# collect the path-ish arguments out of a tool call's input, so `path` patterns
# have something to match. keys are matched by name rather than by position —
# tool schemas vary, and a wrong guess would silently fail open.
def paths-of [input: record]: nothing -> list<string> {
  if $input == null { return [] }
  $input
  | transpose k v
  | where {|c| ($c.v | describe) == "string" and (($c.k | str lowercase | str contains "path") or ($c.k | str lowercase | str contains "cwd") or ($c.k | str lowercase | str contains "file")) }
  | get v
}

# the gate. takes a call record, returns a decision record.
#
# input:  {tool, command, input}
#   tool    the name as the model sees it ("bash", "nu-shell", "mcp__x__y")
#   command the assembled command line, when there is one
#   input   the tool's arguments, for path patterns
export def check [call: record]: nothing -> record {
  let r = (rules)

  let tool = ($call | get --optional tool | default "")
  let command = ($call | get --optional command | default "")
  let input = ($call | get --optional input | default {})
  let paths = (paths-of $input)

  # first match wins: a rules file is read top to bottom and the outcome is
  # predictable from reading it, which beats a specificity rule nobody can hold
  # in their head
  let hit = (
    ($r.rules | enumerate | where {|e|
        let m = ($e.item | get --optional match | default {})
        let want_tool = ($m | get --optional tool)
        let want_cmd = ($m | get --optional command)
        let want_path = ($m | get --optional path)
        let ok_tool = ($want_tool == null) or (matches $want_tool $tool)
        let ok_cmd = ($want_cmd == null) or (($command | is-not-empty) and (matches $want_cmd $command))
        let ok_path = ($want_path == null) or ($paths | any {|p| matches $want_path $p })
        $ok_tool and $ok_cmd and $ok_path
      })
    | get --optional 0
  )

  let decision = (
    if $hit == null { ($r | get --optional default | default "allow") } else { ($hit.item | get --optional action | default "allow") }
  )
  let reason = (
    if $hit == null { "" } else { ($hit.item | get --optional reason | default "") }
  )

  {
    decision: $decision
    rule: (if $hit == null { null } else { $hit.index })
    reason: $reason
    tool: $tool
    command: $command
    paths: $paths
    source: ($r | get --optional source | default "none")
  }
}

# the message a denied or deferred call produces for the model. it is written TO
# the model: state that it is a hard rule, and that retrying is pointless.
export def refuse-message [d: record]: nothing -> string {
  let where = (if $d.rule == null { "the default rule" } else { $"rule ($d.rule)" })
  let why = (if ($d.reason | is-empty) { "" } else { $" — ($d.reason)" })
  let cost = (
    if $d.command == null or ($d.command | is-empty) { $"tool ($d.tool)" } else { $"`($d.command)`" }
  )
  $"policy denied ($cost) by ($where)($why). this is a hard rule in the user's policy file; do not retry the same call. if the task genuinely requires it, say so in your reply so the user can amend the policy."
}

# ── deferred "ask" decisions ──
# a rules file can say `ask`, but there is no way to block for a human when the
# runtime is an MCP server with no terminal. the answer is not to guess and not
# to block: record it and tell the model it is pending.

def pending-path []: nothing -> path {
  $nu.data-dir | path join "policy" | path join "pending.json"
}

def load-pending []: nothing -> list {
  let p = (pending-path)
  if not ($p | path exists) { [] } else { open $p }
}

export def pending []: nothing -> table {
  load-pending
}

# how to resolve an `ask` when there may be nobody to ask.
#
# `prompt` needs a terminal; `defer` is the only answer that keeps a human in
# the loop without blocking an API round. defaulting to defer when stderr is not
# a terminal is what makes this work unchanged under an MCP server.
export def on-ask-mode []: nothing -> string {
  let explicit = ($env.NU_AGENT_ON_ASK? | default "")
  if ($explicit | is-not-empty) { return $explicit }
  if (is-terminal --stderr) { "prompt" } else { "defer" }
}

def verdict-of [d: record, decision: string, reason: string]: nothing -> record {
  {decision: $decision, id: null, rule: $d.rule, reason: $reason, tool: $d.tool, command: $d.command, paths: $d.paths, source: $d.source}
}

# resolve an `ask`, returning a decision record.
export def defer [d: record]: nothing -> record {
  let mode = (on-ask-mode)
  if $mode == "deny" { return (verdict-of $d "deny" "the policy asks for confirmation and --on-ask=deny") }
  if $mode == "allow" { return (verdict-of $d "allow" "the policy asks for confirmation and --on-ask=allow") }

  if $mode == "prompt" {
    # /dev/tty, not stdin: stdout is the tool result, and a prompt written there
    # would end up inside the content handed to the model
    let answer = (try {
        ^sh -c $"printf '%s [y/N] ' (quote sh $d.command) > /dev/tty; read -r a < /dev/tty; printf '%s' $a"
      } catch { "" })
    if (($answer | str trim | str lowercase) in ["y" "yes"]) {
      return (verdict-of $d "allow" "approved at the prompt")
    }
    return (verdict-of $d "deny" "declined at the prompt")
  }

  let id = $"pol-((date now | format date '%Y%m%d-%H%M%S'))-((random int 1000..9999))"
  let p = (pending-path)
  mkdir ($p | path dirname)
  # materialise before writing. `load-pending | append … | save -f $p` reads and
  # writes the same path in one pipeline, and nu refuses that outright
  # ("pipeline input and output are the same file") — it only appeared to work
  # the first time, when there was no file to read yet.
  let updated = ((load-pending) | append {
    id: $id, when: ((date now) | format date '%Y-%m-%d %H:%M:%S')
    tool: $d.tool, command: $d.command, paths: $d.paths, reason: $d.reason
  })
  $updated | save -f $p

  {decision: "defer", id: $id, rule: $d.rule, reason: $d.reason, tool: $d.tool, command: $d.command, paths: $d.paths, source: $d.source}
}

# what a deferred call tells the model
export def defer-message [d: record]: nothing -> string {
  let cost = (if $d.command == null or ($d.command | is-empty) { $"tool ($d.tool)" } else { $"`($d.command)`" })
  $"($cost) is deferred pending user approval \(($d.id)\) — the policy file asks for confirmation and there is no terminal here. do not retry it. carry on with anything else, and tell the user in your reply that this call is waiting."
}

export def approve [id: string]: nothing -> string {
  let p = (pending-path)
  let all = (load-pending)
  let hit = ($all | where id == $id)
  if ($hit | is-empty) { error make { msg: $"no pending call with id ($id)" } }
  ($all | where id != $id) | save -f $p
  $"approved ($id): ($hit.0.command). it is not re-run for you — the caller has to issue it again now that it is no longer pending."
}

# dry-run the rules against the samples in --file, or the rules file's own
# examples. a wrong pattern is invisible until the moment it matters, so there
# has to be a way to look at it beforehand.
export def test [--file: path]: nothing -> table {
  let samples = (
    if $file == null {
      [
        {tool: "bash", command: "ls -la", input: {}}
        {tool: "bash", command: "rm -rf /tmp/x", input: {}}
        {tool: "read", command: "", input: {path: "/etc/hosts"}}
        {tool: "write", command: "", input: {path: "/etc/nginx/nginx.conf"}}
        {tool: "read", command: "", input: {path: "/home/u/.ssh/id_rsa"}}
      ]
    } else {
      open $file
    }
  )
  $samples | each {|s|
    let d = (check $s)
    {tool: $d.tool, command: $d.command, paths: ($d.paths | str join ","), decision: $d.decision, rule: $d.rule, reason: $d.reason}
  }
}

# why a given call got its decision — for writing a rules file without guessing
export def explain [call: record]: nothing -> record {
  let d = (check $call)
  let r = (rules)
  let hit = ($d.rule == null)
  {
    decision: $d.decision
    matched: (if $hit { "no rule — the default applies" } else { $"rule ($d.rule)" })
    rule: (if $hit { null } else { ($r.rules | get $d.rule) })
    tool: $d.tool
    command: $d.command
    paths: $d.paths
    source: $d.source
    rules_loaded: ($r.rules | length)
  }
}
