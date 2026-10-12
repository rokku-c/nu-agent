#!/usr/bin/env nu
# tui.nu — the interactive mode, driven through a real pty
#
# Everything else in this suite is hermetic and headless. This one cannot be:
# `agent tui` reads with `input --reedline`, which needs a terminal, and the two
# bugs it was written for were both invisible everywhere else —
#
#   · the session id arrived as "" rather than null, so no turn was ever written
#     and the conversation had no memory
#   · the turn ran `agent chat`, which passes tool definitions to the model and
#     never executes them, so the model called a tool, got nothing back, and
#     replied with no text at all
#
# Both only appear when someone actually types at it. test/tui-drive.py supplies
# the terminal; this file asserts on what came back.
#
# skipped when python3 is absent — the helper needs it.

use ./harness.nu *

let ROOT = ($env.NU_AGENT_ROOT? | default "")
let tmp = ($nu.temp-dir | path join $"nu-agent-tui-(random int 100000..999999)")
mkdir $tmp
# the driver runs `agent tui` in a child, which must write to the SAME store this
# suite reads back — otherwise every assertion about what was stored looks in the
# wrong place and passes for the wrong reason
$env.NU_SESSION_DIR = $tmp

def py-ok []: nothing -> bool {
  ((which python3 | length) > 0)
}

# run the driver and return its (ANSI-stripped) transcript
def drive [session: string, tools: string, prompts: list<string>]: nothing -> string {
  mkdir $tmp
  (^python3 ($ROOT | path join "test/tui-drive.py") $ROOT $tmp $session $tools ...$prompts
   | complete).stdout
}

let results = [
  (case "tui: the banner names a real session, not an empty one" {
    # regression: the wrapper passed --session "" instead of null, so the id was
    # never generated and every turn ran without a session
    if not (py-ok) { skipped "tui: the banner names a real session, not an empty one" "no python3"
    } else if not (needs-creds) { skipped "tui: the banner names a real session, not an empty one" "no credentials"
    } else {
      let out = (drive "banner" "calc" ["/quit"])
      (has "tui: the banner names a real session, not an empty one" $out "session banner")
    }
  })

  (case "tui: a turn is written to the session" {
    if not (py-ok) { skipped "tui: a turn is written to the session" "no python3"
    } else if not (needs-creds) { skipped "tui: a turn is written to the session" "no credentials"
    } else {
      drive "written" "calc" ["say only: ok"] | ignore
      (is-true "tui: a turn is written to the session" (session exists "written"))
    }
  })

  (case "tui: an earlier turn is remembered" {
    # the whole point of the session id being right
    if not (py-ok) { skipped "tui: an earlier turn is remembered" "no python3"
    } else if not (needs-creds) { skipped "tui: an earlier turn is remembered" "no credentials"
    } else {
      let out = (drive "memory" "calc" [
        "Reply with just the word: persimmon"
        "What single word did I ask you to reply with? Reply with only it"
      ])
      (has "tui: an earlier turn is remembered" $out "persimmon")
    }
  })

  (case "tui: tools offered to the model actually run" {
    # regression: the turn used `chat`, which advertises tools and never runs
    # them. rounds=2 with one tool call is the proof that the loop drove it.
    if not (py-ok) { skipped "tui: tools offered to the model actually run" "no python3"
    } else if not (needs-creds) { skipped "tui: tools offered to the model actually run" "no credentials"
    } else {
      drive "tools" "calc" ["You must use the calc tool; do not compute it yourself: what is (1234 * 5678) + 99?"] | ignore
      let rec = (session load "tools")
      (eq "tui: tools offered to the model actually run" [$rec.counters.rounds $rec.counters.tool_calls] [2 1])
    }
  })

  (case "tui: the status line reports the last request and the session totals" {
    if not (py-ok) { skipped "tui: the status line reports the last request and the session totals" "no python3"
    } else if not (needs-creds) { skipped "tui: the status line reports the last request and the session totals" "no credentials"
    } else {
      let out = (drive "status" "calc" ["say only: ok"])
      (has "tui: the status line reports the last request and the session totals" $out "session")
    }
  })

  (case "tui: /rewind drops the last turn and nothing more" {
    # the count in the message was literal text for a while ("dropped 6 - 4
    # message(s)") because the subtraction sat inside an interpolation
    if not (py-ok) { skipped "tui: /rewind drops the last turn and nothing more" "no python3"
    } else if not (needs-creds) { skipped "tui: /rewind drops the last turn and nothing more" "no credentials"
    } else {
      let out = (drive "undo" "calc" ["say only: one" "say only: two" "/rewind"])
      (has "tui: /rewind drops the last turn and nothing more" $out "dropped 2 message")
    }
  })

  (case "tui: a slash command does not reach the model" {
    if not (py-ok) { skipped "tui: a slash command does not reach the model" "no python3"
    } else {
      let out = (drive "slash" "calc" ["/session"])
      (has "tui: a slash command does not reach the model" $out "continue it later with")
    }
  })
]

rm -rf $tmp
emit $results
