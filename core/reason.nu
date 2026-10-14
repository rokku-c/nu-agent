# reason.nu — getting the real reason out of a nu error
#
#   use reason.nu
#   try { … } catch {|e| reason $e }
#   reason chain $e     # every message on the way down, for a log
#
# ── why this exists ──
# an `error make` raised inside a closure (`each`, `where`, `reduce`, `do`) does not surface
# as itself. nu wraps it in ShellError::EvalBlockWithInput, whose `.msg` is the literal
# string "Eval block failed with pipeline input" — a sentence that names nothing. the cause
# is in the error's `inner` chain instead.
#
# ── the part that is easy to get wrong, and was ──
# reading `.details.inner` ONCE is not enough. each nesting level adds its own wrapper, and
# only the first level hangs off `details`; every level below it hangs off `inner`. measured,
# with `each` inside `each`:
#
#   $e.msg                                 → "Eval block failed with pipeline input"
#   $e.details.inner.0.msg                 → "Eval block failed with pipeline input"  ← same sentence
#   $e.details.inner.0.inner.0.msg         → "DEEP REAL CAUSE"                         ← the answer
#
# so a one-level unwrap hands the wrapper straight back, and what the user reads is exactly
# as useless as it was before the unwrap was added. the agent loop nests closures, so the
# errors that actually reach a person are the deep ones — this is the common case, not a
# corner. the walk below therefore follows `inner` at EVERY level.

# the sentence nu substitutes for the real cause. compared exactly — it is a fixed string —
# and dropped rather than shown, because repeating it tells the reader nothing.
const WRAPPER = "Eval block failed with pipeline input"

# how far the walk goes before giving up: a guard against a self-referential error, not a
# real limit, since nu's nesting is bounded by the closure stack.
const MAX_DEPTH = 8

def msgs-of [nodes: list]: nothing -> list<string> {
  $nodes | each {|n|
    let d = ($n | describe)
    if ($d | str starts-with "record") {
      $n | get --optional msg
    } else if ($d | str starts-with "string") {
      # an `inner` entry is typed list<any>, so it can hold a bare string
      $n
    } else {
      null
    }
  } | compact
}

# the children of one error node. the top level keeps them under `details`, every level below
# that directly under `inner` — see the measurement at the top of this file.
def kids-of [n: any]: nothing -> list {
  # the describe guard is load-bearing, not tidiness: `get --optional` on a string does not
  # return null, it RAISES "only list<any>, table, record, and nothing input data is
  # supported" — so an `inner` that holds a bare string would blow up the walk itself.
  if not (($n | describe) | str starts-with "record") { return [] }
  let d = ($n | get --optional details)
  let src = (if $d == null { $n } else { $d })
  let k = ($src | get --optional inner)
  if $k == null { return [] }
  let kd = ($k | describe)
  if ($kd | str starts-with "list") or ($kd | str starts-with "table") {
    # `each {}` turns a table into a list of its rows, with the rows left intact
    $k | each {|x| $x }
  } else {
    [$k]
  }
}

# every message on the way down, outermost first: ["context", "cause", "root cause"].
# duplicates collapse — the wrapper repeats at every nesting level by construction.
export def chain [e: any]: nothing -> list<string> {
  mut out = []
  mut level = [$e]
  mut depth = 0
  while ($depth < $MAX_DEPTH) and (($level | length) > 0) {
    $out = ($out | append (msgs-of $level))
    mut next = []
    for n in $level {
      for k in (kids-of $n) {
        $next = ($next | append $k)
      }
    }
    $level = $next
    $depth = $depth + 1
  }
  $out | uniq
}

# ── the last resort ──
# reachable only when the chain holds nothing but the wrapper — an error with no `inner` at
# all. `rendered` is nu's own pretty-print of the whole failure, and its LAST block is the
# innermost error, i.e. the real one. that makes this a scrape rather than a read, which is
# why it sits behind the structured walk instead of in front of it.
def from-rendered [e: any]: nothing -> any {
  let r = ($e | get --optional rendered | default "")
  if ($r | is-empty) { return null }
  let marked = (
    $r | lines
    | each {|l| $l | str trim }
    | where {|l| ($l | str starts-with "x ") }
  )
  if ($marked | is-empty) { null } else { ($marked | last) | str substring 2.. }
}

# the real reason, as one line, for a person to read.
#   no wrapping at all     → the message itself
#   wrapped once           → the inner message
#   wrapped N times        → the innermost message
#   several real messages  → joined " | ", outermost first, so the context survives
export def main [e: any]: nothing -> string {
  let full = (chain $e)
  let real = ($full | where {|m| $m != $WRAPPER })
  if ($real | is-not-empty) { return ($real | str join " | ") }

  let scraped = (from-rendered $e)
  if $scraped != null { return $scraped }

  # nothing legible anywhere. say that, rather than inventing a reason — and say it in a way
  # that cannot be mistaken for the real answer.
  $"unreadable error: ($full | length) message\(s\), all the wrapper. the full record is in the log"
}
