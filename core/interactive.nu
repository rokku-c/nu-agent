# interactive.nu — the interactive mode
#
# (the file is not called tui.nu because the `agent` module exports a command
# named `tui`, and a module and a command of the same name collide: inside
# agent.nu, `tui repl` resolved to agent's own `tui` command and took `repl` as
# a positional argument.)
#
#   agent tui                       # start a new conversation
#   agent tui --resume              # continue the newest one
#   agent tui --session my-work     # continue a named one
#   agent tui --tools-from [read shell nu-shell]
#
# ── what this is, precisely ──
# a line-based interactive session, not a full-screen one. the input line is read
# with nushell's `input --reedline`, which is a real line editor: arrow keys,
# word motions, Ctrl-R history search, and bracketed paste all work because
# reedline implements them. a full-screen TUI would mean drawing the transcript
# myself and reading keystrokes one at a time (`input --numchar 1`), which is
# possible — but then editing, paste and unicode width become mine to get right,
# and getting them wrong is worse than not having a frame.
#
# ── what a turn does ──
# each line is one `agent chat` turn against the same session, streamed. the
# session is written per turn, so quitting, crashing, or closing the terminal
# loses at most the turn in flight — and `agent tui --resume` picks it up.
#
# ── why the model is told what it has ──
# `/tools` and `/model` change the run, not the conversation, so they are printed
# and remembered here; the transcript keeps only what was actually said.

use ./reason.nu
use ./session.nu
use ./shells.nu

# "" and null both mean "not set" — see the note where sid is resolved.
def unset [v: any]: nothing -> any {
  if $v == null or $v == "" { null } else { $v }
}

const HISTORY_FILE = "tui-history.txt"

# where reedline keeps the input history. under the session store, so a project
# with its own NU_SESSION_DIR gets its own command history too.
def history-path []: nothing -> path {
  let d = (session store-dir)
  mkdir $d
  $d | path join $HISTORY_FILE
}

# token counts read badly as six digits; k is enough resolution to see a
# conversation growing, which is the only thing this is for
def fmt-tokens [n: any]: nothing -> string {
  let v = ($n | default 0 | into int)
  if $v >= 1000000 { $"($v / 1000000 | math round --precision 1)M"
  } else if $v >= 1000 { $"($v / 1000 | math round --precision 1)k"
  } else { $v | into string }
}

# what the conversation has cost so far, and what the last request cost.
#
# two numbers because they answer different questions: the last request is what
# the context costs right now (and what folding will act on), the session total
# is what the whole conversation has spent.
def status-line [sid: string]: nothing -> string {
  if not (session exists $sid) { return "" }
  let c = ((session load $sid) | get --optional counters | default {})
  let li = ($c | get --optional last_input_tokens | default 0)
  let lo = ($c | get --optional last_output_tokens | default 0)
  let ti = ($c | get --optional total_input | default 0)
  let to = ($c | get --optional total_output | default 0)
  let turns = ($c | get --optional rounds | default 0)
  let label = (if $turns == 1 { "round" } else { "rounds" })
  $"  · last request (fmt-tokens $li) in / (fmt-tokens $lo) out · session (fmt-tokens $ti) in / (fmt-tokens $to) out · ($turns) ($label)"
}

const HELP = [
  "commands:"
  "  /help              this"
  "  /session           show the current session and how to reach it again"
  "  /new [id]          start a fresh conversation"
  "  /resume [id]       continue the newest session, or a named one"
  "  /tools [a,b,c]     show or set which capability modules are offered"
  "  /model [name]      show or set the model"
  "  /system [text]     show or set the system prompt"
  "  /rewind            drop the last turn, so you can ask it again"
  "  /status            context and token totals for this session"
  "  /shell [name]      which shell the shell tool runs through (a path or a basename)"
  "  /verbose           toggle showing tool calls and their results"
  "  /thinking          toggle streaming the model's reasoning"
  "  /history [n]       the last n turns of this session"
  "  /clear             clear the screen"
  "  /quit  /exit       leave"
  ""
  "anything else is sent to the model."
]

def banner [sid: string, model: string, provider: string, tools: list<string>]: nothing -> string {
  let t = (if ($tools | is-empty) { "none" } else { $tools | str join ", " })
  [
    $"nu-agent · session ($sid)"
    $"  model    ($model)  \(($provider)\)"
    $"  tools    ($t)"
    "  /help for commands, /quit to leave"
  ] | str join (char nl)
}

# ── why the turn is a closure, not a call to `agent chat` ──
# a nushell module does NOT inherit the scope of whoever imported it. this file
# cannot see `agent`, and `use ./agent.nu` here would be circular — agent.nu
# imports this one to expose `agent tui`.
#
# so the caller passes the turn in. `repl` owns the terminal, the commands and
# the session bookkeeping; whatever `--send` does with a line is the caller's
# business. it also means this loop is testable without a model.
def turn [send: closure, req: record]: nothing -> nothing {
  do $send $req
}

# the interactive loop
export def repl [
  --send: closure                 # {line, session, resume, tools, model, provider, system, max_tokens} -> nothing
  --session (-S): string
  --resume
  --tools-from: list<string> = ["read" "write" "edit" "shell"]
  --model (-m): string
  --provider (-p): string
  --system (-s): string
  --max-tokens (-t): int = 32000   # see the note in agent.nu: thinking spends from this too
  --verbose (-v)                  # show tool calls and their results
  --show-thinking                 # stream the model's reasoning
  --no-save
]: nothing -> nothing {
  # ── the starting session ──
  # `unset`, because a wrapper passing "" means the same as not passing it,
  # and "" is not null — the check below would skip and every turn would run
  # with an empty session id.
  mut sid = (unset $session)
  mut resuming = $resume
  if $resuming and ($sid == null) {
    let newest = (session last)
    if $newest == null {
      print -e "no sessions to resume — starting a new one"
      $resuming = false
    } else {
      $sid = $newest.id
    }
  }
  if $sid == null { $sid = (session new-id) }
  if $resuming and not (session exists $sid) {
    error make { msg: $"session ($sid) does not exist" }
  }

  mut tools = $tools_from
  mut model = (unset $model)
  mut sys = (unset $system)
  # toggled at runtime, because whether you want the machinery visible depends on
  # what you are doing — reading a tool's output matters when it is wrong and is
  # noise when it is not
  mut verbose = $verbose
  mut thinking = $show_thinking

  print (banner $sid ($model | default "(from env)") ($provider | default "(inferred)") $tools)
  print ""

  # ── nothing here may be wrapped in `try` ──
  # measured: `try { input --reedline … }` returns "" immediately and forever
  # instead of waiting for a line, so the loop spins at full speed printing
  # nothing. the same happens if the enclosing `while` sits inside a try. the read
  # — and therefore this whole loop — has to be bare. Ctrl-D ends the session
  # through nushell's own error path; /quit is the clean way out, and either way
  # the turn-by-turn saves mean nothing is lost.
  mut turn = 0
  mut running = true
  while $running {
    # the turn number rides in the prompt, which is the only place it can be
    # without adding a line of its own
    let line = (input --reedline --history-file (history-path) $"Turn ($turn + 1) › ")
    let text = ($line | str trim)
    if ($text | is-empty) { continue }

    # ── slash commands ──
    if ($text | str starts-with "/") {
      let parts = ($text | split row " ")
      let cmd = ($parts | first)
      let rest = ($parts | skip 1 | str join " " | str trim)

      if ($cmd in ["/quit" "/exit" "/q"]) {
        $running = false
      } else if $cmd == "/help" {
        print ($HELP | str join (char nl))
      } else if $cmd == "/clear" {
        clear
      } else if $cmd == "/session" {
        print $"session: ($sid)"
        print $"  continue it later with:  agent tui --resume --session ($sid)"
        print $"  read it with:            session show ($sid)"
      } else if $cmd == "/new" {
        $sid = (if ($rest | is-empty) { session new-id } else { $rest })
        $resuming = false
        print $"new session: ($sid)"
      } else if ($cmd in ["/resume" "/continue"]) {
        let target = (if ($rest | is-empty) { (session last | get --optional id) } else { $rest })
        if $target == null {
          print -e "no sessions to resume"
        } else if not (session exists $target) {
          print -e $"no such session: ($target)"
        } else {
          $sid = $target
          $resuming = true
          let n = ((session load $sid).messages | length)
          print $"continuing ($sid) — ($n) messages stored"
        }
      } else if $cmd == "/tools" {
        if ($rest | is-empty) {
          print $"tools: ($tools | str join ', ')"
          print "  (set with /tools read,shell)"
        } else {
          $tools = ($rest | split row "," | each {|t| $t | str trim } | where {|t| $t | is-not-empty })
          print $"tools: ($tools | str join ', ')"
        }
      } else if $cmd == "/model" {
        if ($rest | is-empty) { print $"model: ($model | default 'from env')" } else { $model = (unset $rest); print $"model: ($rest)" }
      } else if $cmd == "/system" {
        if ($rest | is-empty) {
          print $"system: ($sys | default '(none)')"
        } else {
          $sys = $rest
          print $"system: ($sys)"
        }
      } else if ($cmd in ["/rewind"]) {
        # the functional part of a rewind. double-ESC cannot be done here: the
        # input line is read by reedline, which consumes escape sequences itself,
        # so this loop never sees a key — see the note at the top of the file.
        if not (session exists $sid) {
          print -e "nothing to rewind yet"
        } else {
          let rec = (session load $sid)
          let msgs = ($rec | get --optional messages | default [])
          let last_user = ($msgs | enumerate | where {|r| ($r.item | get --optional role) == "user" } | last | get --optional index)
          if $last_user == null {
            print -e "nothing to rewind"
          } else {
            $rec | upsert messages ($msgs | first $last_user) | session store | ignore
            print $"dropped (($msgs | length) - $last_user) message\(s\), back to before your last turn"
            print "  ask again and it continues from there"
          }
        }
      } else if $cmd == "/shell" {
        if ($rest | is-empty) {
          print $"shell: (shells resolve null)"
          print $"  available: (shells available | each {|p| $p | path basename } | str join ', ')"
        } else {
          # a basename is enough: /bin/fish and /opt/homebrew/bin/fish are the same answer
          let want = ($rest | path basename)
          let hit = (shells available | where {|p| ($p | path basename) == $want })
          if ($hit | is-empty) {
            print -e $"no shell named ($want). try: (shells available | each {|p| $p | path basename } | str join ', ')"
          } else {
            $env.NU_AGENT_SHELL = $hit.0
            print $"shell: ($hit.0) — for the rest of this session"
            print "  (set NU_AGENT_SHELL in your environment to make it stick)"
          }
        }
      } else if $cmd == "/status" {
        let line = (status-line $sid)
        if ($line | is-empty) { print -e "nothing stored yet" } else { print $line }
      } else if ($cmd in ["/verbose" "/v"]) {
        $verbose = (if ($rest | is-empty) { not $verbose } else { $rest in ["on" "true" "1"] })
        print $"verbose: (if $verbose { 'on — tool calls and results' } else { 'off' })"
      } else if ($cmd in ["/thinking" "/think"]) {
        $thinking = (if ($rest | is-empty) { not $thinking } else { $rest in ["on" "true" "1"] })
        print $"thinking: (if $thinking { 'on — the reasoning stream' } else { 'off' })"
      } else if $cmd == "/history" {
        let n = (if ($rest | is-empty) { 6 } else { $rest | into int })
        if not (session exists $sid) {
          print -e "nothing yet"
        } else {
          let msgs = ((session load $sid).messages | default [])
          let from = ([ (($msgs | length) - $n) 0 ] | math max)
          $msgs | enumerate | skip $from | each {|r|
              let c = ($r.item | get --optional content)
              let t = (if (($c | describe) | str starts-with "string") { $c } else { $"($c | length) blocks" })
              print $"  ($r.index) [($r.item.role)] ($t | str replace -r -a '\s+' ' ' | str substring 0..90)"
            }
        }
      } else {
        print -e $"unknown command ($cmd) — /help"
      }
      continue
    }

    # ── a turn ──
    try {
      turn $send {
        line: $text, session: $sid, resume: $resuming
        tools: $tools, model: $model, provider: $provider, system: $sys
        max_tokens: $max_tokens, no_save: $no_save
        verbose: $verbose, thinking: $thinking
      }
      # after the first turn the session exists, so it is resumed from then on
      $resuming = true
      $turn = $turn + 1
      # what the turn cost. printed here rather than by the loop so it appears
      # once per turn rather than once per round.
      let st = (status-line $sid)
      if ($st | is-not-empty) { print $st }
      if $no_save { print -e "(not saved: --no-save)" }
    } catch {|e|
      # a failed turn must not take the session down with it — the transcript so
      # far is already on disk, and the next line continues from it.
      # through `reason`, not `.msg`: a turn failure comes out of the agent loop,
      # which nests closures, so `.msg` is the wrapper and says nothing
      print -e $"turn failed: (reason $e)"
    }
    # NO blank line here. the loop already emits one after every round that
    # produced text, which for a finished turn is the last one — so a separator
    # here made two, every time. the loop's is the right one: it exists to keep a
    # following round from sticking to the text, and it fires once per turn.
  }

  print $"session ($sid)"
  print $"  continue: agent tui --resume --session ($sid)"
}
