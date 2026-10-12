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
#   agent tui --tools-from [read bash nu-shell]
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

use ./session.nu

const HISTORY_FILE = "tui-history.txt"

# where reedline keeps the input history. under the session store, so a project
# with its own NU_SESSION_DIR gets its own command history too.
def history-path []: nothing -> path {
  let d = (session store-dir)
  mkdir $d
  $d | path join $HISTORY_FILE
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
  --tools-from: list<string> = ["read" "calc" "nu-shell"]
  --model (-m): string
  --provider (-p): string
  --system (-s): string
  --max-tokens (-t): int = 4096
  --no-save
]: nothing -> nothing {
  # ── the starting session ──
  mut sid = ($session | default null)
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
  mut model = $model
  mut sys = $system

  print (banner $sid ($model | default "(from env)") ($provider | default "(inferred)") $tools)
  print ""

  # ── nothing here may be wrapped in `try` ──
  # measured: `try { input --reedline … }` returns "" immediately and forever
  # instead of waiting for a line, so the loop spins at full speed printing
  # nothing. the same happens if the enclosing `while` sits inside a try. the read
  # — and therefore this whole loop — has to be bare. Ctrl-D ends the session
  # through nushell's own error path; /quit is the clean way out, and either way
  # the turn-by-turn saves mean nothing is lost.
  mut running = true
  while $running {
    let line = (input --reedline --history-file (history-path) "› ")
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
          print "  (set with /tools read,bash)"
        } else {
          $tools = ($rest | split row "," | each {|t| $t | str trim } | where {|t| $t | is-not-empty })
          print $"tools: ($tools | str join ', ')"
        }
      } else if $cmd == "/model" {
        if ($rest | is-empty) { print $"model: ($model | default 'from env')" } else { $model = $rest; print $"model: ($model)" }
      } else if $cmd == "/system" {
        if ($rest | is-empty) {
          print $"system: ($sys | default '(none)')"
        } else {
          $sys = $rest
          print $"system: ($sys)"
        }
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
      }
      # after the first turn the session exists, so it is resumed from then on
      $resuming = true
      if $no_save { print -e "(not saved: --no-save)" }
    } catch {|e|
      # a failed turn must not take the session down with it — the transcript so
      # far is already on disk, and the next line continues from it
      print -e $"turn failed: ($e.msg)"
    }
    print ""
  }

  print $"session ($sid)"
  print $"  continue: agent tui --resume --session ($sid)"
}
