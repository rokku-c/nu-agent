# handoff.nu — continue a conversation another agent was having
#
#   use handoff.nu
#
#   handoff sources                      # which agents we can read, and how many sessions
#   handoff list                         # recent sessions across all of them
#   handoff list --from claude-code --cwd .
#   handoff read claude-code 835031fb    # what it would import, without importing
#   handoff import claude-code 835031fb --into my-work
#   handoff import codex 01a0d186 --tail 20
#
#   then, in nu:
#   agent "carry on from where that left off" --resume --session my-work
#
# ── what a handoff is, and what it is not ──
# it imports the CONVERSATION: the user and assistant text, in order. it does
# not import tool calls. three agents represent tools three different ways, and
# the calls they made are not nu commands — a `function_call` for a codex shell
# tool has no nu equivalent, and replaying it through nu-agent's tool loop would
# tell the model it had run something it had not.
#
# so tool calls are counted and reported rather than migrated, and the imported
# session is stamped with where it came from. a resumed run says so in its
# system prompt, including that tools named in the older transcript may not
# exist or may behave differently here.
#
# ── why only a tail is loaded ──
# these transcripts get large — the one this was written against holds 700+
# messages across 4000 tool calls. loading all of it would spend the whole
# context on a conversation the model did not have, so a handoff records how
# much to load by default and the rest stays in the store, readable with
# `session show`.

use ./session.nu

const DEFAULT_TAIL = 40

# where each agent keeps its transcripts. measured on this machine; a missing
# root just means that agent has never run here.
#
# one private table, two readers: `sources` reports it, `files-of` globs it. the
# glob pattern is deliberately not in the public table — it is an implementation
# detail, and a column nobody reads is a column that drifts.
def known []: nothing -> table {
  [
    {agent: "claude-code", root: "~/.claude/projects",   pattern: "**/*.jsonl"}
    {agent: "codex",       root: "~/.codex/sessions",    pattern: "**/rollout-*.jsonl"}
    {agent: "pi",          root: "~/.pi/agent/sessions", pattern: "**/*.jsonl"}
  ]
}

export def sources []: nothing -> table {
  known | each {|k|
      let root = ($k.root | path expand)
      let files = (if ($root | path exists) { glob ($root | path join $k.pattern) } else { [] })
      {agent: $k.agent, root: ($root | into string), sessions: ($files | length)}
    }
}

def files-of [agent: string]: nothing -> list<string> {
  let k = (known | where agent == $agent)
  if ($k | is-empty) {
    error make { msg: $"unknown agent: ($agent). known: (known | get agent | str join ', ')" }
  }
  if not ($k.0.root | path expand | path exists) {
    error make { msg: $"($agent) has no sessions here: ($k.0.root) does not exist" }
  }
  glob ($k.0.root | path expand | path join $k.0.pattern)
}

# ── the three readers ──
#
# each returns {id, path, cwd, when, messages, tools_skipped}. `messages` is
# canonical: {role, content} with content a plain string, which is all a
# handoff carries.

# codex opens every session by injecting its own harness context as a user turn
# (`<environment_context>`, `<user_shell_command>`). that is not something the
# human said, and importing it puts a wall of cwd/date noise at the top of the
# new conversation. dropped by tag, so a real message that merely contains `<`
# survives.
const HARNESS_TAGS = ["<environment_context>" "<user_shell_command>" "<turn_aborted>" "<system_reminder>"]

def is-harness [text: string]: nothing -> bool {
  let t = ($text | str trim | str substring 0..([ 40 ($text | str trim | str length) ] | math min))
  $HARNESS_TAGS | any {|tag| $t | str starts-with $tag }
}

# a message's text, from either a plain string or a block list. only `text`
# blocks count — thinking is the other agent's private reasoning, and tool
# blocks are deliberately dropped (see the header).
def text-of [content: any]: nothing -> string {
  if $content == null { return "" }
  let d = ($content | describe)
  if ($d | str starts-with "string") { return $content }
  if (($d | str starts-with "list") or ($d | str starts-with "table")) {
    return (
      $content
      | where {|b| ($b | get --optional type) in ["text" "input_text" "output_text"] }
      | get --optional text
      | default []
      | str join (char nl)
    )
  }
  ($content | into string)
}

def count-tools [content: any]: nothing -> int {
  if $content == null { return 0 }
  let d = ($content | describe)
  if not (($d | str starts-with "list") or ($d | str starts-with "table")) { return 0 }
  ($content | where {|b| ($b | get --optional type) in ["tool_use" "tool_result" "tool_call" "tool_result_block"] } | length)
}

# read a jsonl transcript, yielding only the lines that parse. a half-written
# last line is normal (the agent may still be running) and must not be fatal.
def jsonl [path: path]: nothing -> list {
  open --raw $path
  | lines
  | each {|l| try { $l | from json } catch { null } }
  | compact
}

# just the head. listing needs id/cwd/when and nothing else, and a full parse of
# a 4000-tool-call transcript costs most of a second — 60 of those is a listing
# nobody waits for. metadata is near the top in all three formats.
def head-jsonl [path: path]: nothing -> list {
  ^head -n 12 $path
  | lines
  | each {|l| try { $l | from json } catch { null } }
  | compact
}

# the same {id, path, cwd, when} every reader returns, without the messages
def meta-of [agent: string, path: path]: nothing -> record {
  let head = (head-jsonl $path)
  if $agent == "claude-code" {
    let m = ($head | where {|r| ($r | get --optional cwd) != null } | first)
    {id: ($path | path parse | get stem), path: ($path | into string), cwd: ($m | get --optional cwd | default ""), when: (($head | where {|r| ($r | get --optional type) == "user" } | first | get --optional timestamp) | default "")}
  } else if $agent == "codex" {
    let m = ($head | where {|r| ($r | get --optional type) == "session_meta" } | first)
    {id: ($m | get --optional payload.id | default ($path | path parse | get stem)), path: ($path | into string), cwd: ($m | get --optional payload.cwd | default ""), when: ($m | get --optional payload.timestamp | default "")}
  } else {
    let m = ($head | where {|r| ($r | get --optional type) == "session" } | first)
    {id: ($m | get --optional id | default ($path | path parse | get stem)), path: ($path | into string), cwd: ($m | get --optional cwd | default ""), when: ($m | get --optional timestamp | default "")}
  }
}

# claude-code: ~/.claude/projects/<slug>/<uuid>.jsonl
#   {type: "user"|"assistant", message: {role, content}, isSidechain, cwd, gitBranch, timestamp}
# sidechain entries are a subagent's own conversation, not this one.
def read-claude-code [path: path]: nothing -> record {
  let rows = (jsonl $path)
  let msgs = (
    $rows
    | where {|r| (($r | get --optional type) in ["user" "assistant"]) and (not ($r | get --optional isSidechain | default false)) }
  )
  let meta = ($rows | where {|r| ($r | get --optional cwd) != null } | first)
  {
    id: ($path | path parse | get stem)
    path: ($path | into string)
    cwd: ($meta | get --optional cwd | default "")
    when: (($msgs | first | get --optional timestamp) | default "")
    messages: (
      $msgs
      | each {|r|
          let c = ($r | get --optional message.content)
          {role: ($r | get --optional message.role | default "user"), content: (text-of $c)}
        }
      | where {|m| ($m.content | str trim) | is-not-empty }
    )
    tools_skipped: ($msgs | each {|r| count-tools ($r | get --optional message.content) } | math sum)
  }
}

# codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
#   {type: "session_meta", payload: {id, cwd}}
#   {type: "response_item", payload: {type: "message", role, content: [{type: input_text|output_text, text}]}}
# tool calls are separate response_item payload types (function_call, …), so they
# are counted from those rather than from the message content.
def read-codex [path: path]: nothing -> record {
  let rows = (jsonl $path)
  let meta = ($rows | where {|r| ($r | get --optional type) == "session_meta" } | first)
  let msgs = (
    $rows
    | where {|r| (($r | get --optional type) == "response_item") and (($r | get --optional payload.type) == "message") }
  )
  {
    id: ($meta | get --optional payload.id | default ($path | path parse | get stem))
    path: ($path | into string)
    cwd: ($meta | get --optional payload.cwd | default "")
    when: ($meta | get --optional payload.timestamp | default "")
    messages: (
      $msgs
      | each {|r|
          let pl = ($r | get --optional payload | default {})
          {role: ($pl | get --optional role | default "user"), content: (text-of ($pl | get --optional content))}
        }
      # `developer` turns are the harness's own instructions, not the conversation
      | where {|m| ($m.role in ["user" "assistant"]) and ((($m.content | str trim) | is-not-empty)) and (not (is-harness $m.content)) }
    )
    tools_skipped: ($rows | where {|r| (($r | get --optional payload.type) in ["function_call" "function_call_output"]) } | length)
  }
}

# pi: ~/.pi/agent/sessions/<slug>/<ts>_<uuid>.jsonl
#   {type: "session", id, cwd}   then   {type: "message", message: {role, content}}
def read-pi [path: path]: nothing -> record {
  let rows = (jsonl $path)
  let meta = ($rows | where {|r| ($r | get --optional type) == "session" } | first)
  let msgs = ($rows | where {|r| ($r | get --optional type) == "message" })
  {
    id: ($meta | get --optional id | default ($path | path parse | get stem))
    path: ($path | into string)
    cwd: ($meta | get --optional cwd | default "")
    when: ($meta | get --optional timestamp | default "")
    messages: (
      $msgs
      | each {|r|
          let m = ($r | get --optional message | default {})
          {role: ($m | get --optional role | default "user"), content: (text-of ($m | get --optional content))}
        }
      | where {|m| ($m.role in ["user" "assistant"]) and ((($m.content | str trim) | is-not-empty)) }
    )
    tools_skipped: ($msgs | each {|r| count-tools ($r | get --optional message.content) } | math sum)
  }
}

# Read ONE file into canonical form. This is the layer that knows the three
# formats; `read` is the same thing after resolving a short id to a path, and it
# is public so the format work can be tested against synthetic transcripts
# instead of whatever happens to be in ~/.claude on the machine running the tests.
export def parse [agent: string, path: path]: nothing -> record {
  if $agent == "claude-code" { read-claude-code $path }   else if $agent == "codex" { read-codex $path }   else if $agent == "pi" { read-pi $path }   else { error make { msg: $"unknown agent: ($agent). known: (known | get agent | str join ', ')" } }
}

def reader [agent: string]: nothing -> closure {
  if $agent == "claude-code" { {|p| read-claude-code $p} }   else if $agent == "codex" { {|p| read-codex $p} }   else if $agent == "pi" { {|p| read-pi $p} }   else { error make { msg: $"unknown agent: ($agent)" } }
}

# ── discovery ──

# recent sessions, newest first. `id` is what `read` and `import` take.
export def list [
  --from: string          # one agent; default is all of them
  --limit (-l): int = 20  # per agent
  --cwd: path             # only sessions whose recorded cwd is this
]: nothing -> table {
  let agents = (if ($from | is-empty) { sources | where sessions > 0 | get agent } else { [$from] })
  let want = (if $cwd == null { null } else { $cwd | path expand | into string })

  $agents
  | each {|a|
      let r = (reader $a)
      # filter on cheap metadata FIRST, then fully parse only what survives — the
      # other order parses every candidate just to throw most of them away
      # `ls ...$files` in ONE call. sorting with `ls` inside the closure cost one
      # process per file — 2352 of them, and the listing took four seconds.
      (ls ...(files-of $a) | sort-by modified --reverse | get name)
      | each {|f| try { meta-of $a $f } catch { null } }
      | compact
      | where {|s| $want == null or $s.cwd == $want }
      | first $limit
      | each {|s|
          let full = (try { do $r $s.path } catch { null })
          if $full == null { return null }
          {
            agent: $a
            id: (($s.id | into string) | str substring 0..7)
            when: ($s.when | into string | str substring 0..16)
            cwd: ($s.cwd | str replace -r $"^($env.HOME)" "~" | str substring 0..28)
            messages: ($full.messages | length)
            tools: $full.tools_skipped
            title: (($full.messages | where {|m| $m.role == "user" and (not (is-harness $m.content)) } | first | get --optional content | default "(no user turn)") | str replace -r -a '\s+' ' ' | str substring 0..50)
          }
        }
      | compact
    }
  | flatten
}

# resolve a short id (or a path) to the one file it names
export def path-of [agent: string, id: string]: nothing -> path {
  let p = ($id | path expand)
  if ($p | path exists) { return $p }
  let hits = (files-of $agent | where {|f| ($f | path parse | get stem) | str contains $id })
  if ($hits | is-empty) {
    error make { msg: $"no ($agent) session matching '($id)'. try `handoff list --from ($agent)`" }
  }
  if ($hits | length) > 1 {
    error make { msg: $"($hits | length) ($agent) sessions match '($id)': ($hits | each {|h| $h | path parse | get stem } | str join ', '). give more of the id." }
  }
  $hits.0
}

# what an import would bring in, without importing it
export def read [agent: string, id: string]: nothing -> record {
  do (reader $agent) (path-of $agent $id)
}

# ── import ──

# Turn another agent's session into a nu-agent session.
#
# The whole conversation is stored; `--tail` records how much of it a resumed
# run loads by default. Nothing is summarised or rewritten — the older part is
# simply not loaded, and `session show` reads it back.
export def import [
  agent: string
  id: string
  --into (-i): string       # the new session id; generated when omitted
  --tail (-t): int = $DEFAULT_TAIL
  --dry-run                 # report, write nothing
]: nothing -> record {
  let src = (read $agent $id)
  let msgs = ($src.messages | default [])

  if ($msgs | is-empty) {
    error make { msg: $"($agent) session ($id) has no user/assistant turns to import" }
  }

  let sid = ($into | default null | default (session new-id))
  let rec = (session record-of
    --id $sid
    --status "handoff"
    --prompt (($msgs | where role == "user" | first | get --optional content | default "(imported)") | str replace -r -a '\s+' ' ')
    --messages $msgs
    # deliberately NOT a provider name: `provider` means "which dialect", and a
    # handoff has no opinion. writing "handoff" there made resume try to resolve
    # it as a dialect and fail. provenance lives in `handoff.from`.
    --provider ""
    --model ""
    --handoff {
      from: $agent
      source: $src.path
      source_id: ($src.id | into string)
      imported: ((date now) | format date '%Y-%m-%d %H:%M:%S')
      messages: ($msgs | length)
      tools_skipped: ($src.tools_skipped | default 0)
      cwd: ($src.cwd | default "")
      tail: $tail
    }
  )

  if not $dry_run { $rec | session store | ignore }

  {
    session: $sid
    from: $agent
    source: $src.path
    messages: ($msgs | length)
    loaded_by_default: ([ $tail ($msgs | length) ] | math min)
    tools_skipped: ($src.tools_skipped | default 0)
    stored: (not $dry_run)
  }
}

# the note a resumed handoff puts in front of the model.
#
# it says three things on purpose: where this came from, that older history
# exists but was not loaded, and that tools named in it are not this runtime's.
export def note [h: record, loaded: int, total: int]: nothing -> string {
  let earlier = ($total - $loaded)
  let tools = ($h | get --optional tools_skipped | default 0)
  mut lines = [
    "## continuing a conversation from another agent"
    ""
    $"This session was imported from **($h.from)** \(source: `($h | get --optional source_id | default '?')`, imported ($h | get --optional imported | default '?')\)."
    $"The ($loaded) messages below are its most recent."
  ]
  if $earlier > 0 {
    $lines = ($lines | append $"($earlier) earlier messages were NOT loaded — they are stored and can be read with `session show`. Ask if you need them.")
  }
  if $tools > 0 {
    $lines = ($lines | append $"($tools) tool calls from ($h.from) were not carried over. The transcript may name tools or commands that do not exist here, or that behave differently — do not assume an earlier tool ran in this environment, and check before relying on its result.")
  }
  $lines | str join (char nl)
}
