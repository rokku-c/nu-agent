# trig.nu — rules stated in advance, and the daily node that checks them
#
#   use trig.nu
#
#   trig rule --subject "SSE" --symbol sh000001 --via close \
#             --condition below --level 3700 --note "add on the dip to the 250d low"
#   trig rule --subject "UST 10Y" --symbol sh000001 --via close \
#             --condition above --level 3800 --node 2026-11-01
#   trig check
#   trig list
#
# ── what a trigger is, and what it is not ──
# a rule is a statement of intent made in ADVANCE, and it is recorded when it is made — not
# when it fires. that ordering is the whole value: a condition written down before the fact
# can be evaluated honestly, while one invented afterwards is a rationalisation wearing the
# same words.
#
# firing reports "the condition you stated is now met". it does NOT report a recommendation,
# and this module never says buy or sell. execution stays outside, where it belongs — a
# system that lets a module's output become an order has quietly deleted the boundary
# between an opinion and an instruction.
#
# ── why firing is a separate file ──
# same discipline as the prediction archive: the rule is what you said earlier, the firing
# is what the world did later. merging them would erase the gap between the two, and it is
# also what stops a rule from alerting on the same condition every single morning.

use ./market.nu

const DIR_NAME = "nu-agent-triggers"

def now-epoch []: nothing -> int { (date now | format date "%s") | into int }
def today []: nothing -> string { date now | format date "%Y-%m-%d" }

def store-dir []: nothing -> path {
  let override = ($env.NU_AGENT_TRIG_DIR? | default "")
  if ($override | is-empty) { $nu.data-dir | path join $DIR_NAME } else { $override | path expand }
}

def rule-path [id: string]: nothing -> path { store-dir | path join $"($id).rule.json" }
def fired-path [id: string]: nothing -> path { store-dir | path join $"($id).fired.json" }

def all [suffix: string]: nothing -> list<record> {
  if not ((store-dir) | path exists) { return [] }
  glob (store-dir | path join $"*($suffix)")
  | each {|p| try { open $p } catch { null } }
  | compact
}

# observe the current value a rule is stated against. returns null when the instrument did
# not produce a number — a missing observation must never read as "condition not met",
# because silence and a false are different things and only one of them is information.
def observe [symbol: string, via: string]: nothing -> any {
  let recs = (
    if $via == "quote" {
      market quote $symbol
    } else if $via == "close" {
      market history $symbol --limit 5
    } else {
      error make { msg: $"unknown --via '($via)': use quote (a live snapshot) or close (the last daily bar)" }
    }
  )
  # an equity/fx snapshot names its series two different ways: `sh000001:close` from the
  # K-line and quote parsers, but a bare `fx_susdcnh` from the FX snapshot, which carries a
  # single rate and no field. both are looked for, because a rule stated against either
  # should be checkable.
  let hit = ($recs | where {|r| $r.series == $"($symbol):close" or $r.series == $symbol } | last)
  if $hit == null { return null }
  {value: $hit.value, period: $hit.reference_period, source: $hit.source}
}

# ── commands ──

# state a rule. never modified afterwards — a new rule supersedes the old one by naming it.
export def rule [
  --subject: string        # what it is about, in your words
  --symbol: string         # the instrument to watch, e.g. sh000001
  --via: string = "close"  # close (the last daily bar) | quote (a live snapshot)
  --condition: string      # above | below
  --level: float           # the price the condition is stated against
  --node: string           # earliest date this may fire, e.g. 2026-11-01 — the "定时" half
  --note: string
]: nothing -> record {
  if $subject == null { error make { msg: "--subject is required" } }
  if $symbol == null { error make { msg: "--symbol is required" } }
  if $level == null { error make { msg: "--level is required: a price condition with no price is not a condition" } }
  if not ($condition in ["above" "below"]) {
    error make { msg: $"condition must be above or below, got '($condition)'" }
  }
  mkdir (store-dir)
  let id = $"trig-((now-epoch))-(random int 1000..9999)"
  let r = {
    id: $id
    made_at: (date now | format date "%Y-%m-%dT%H:%M:%S")
    subject: $subject
    symbol: $symbol
    via: $via
    condition: $condition
    level: $level
    node: $node
    note: $note
  }
  $r | save -f (rule-path $id)
  $r
}

# every rule, with what has become of it
export def list []: nothing -> any {
  let fired = (all ".fired.json" | reduce --fold {} {|f, acc| $acc | upsert $f.id $f })
  all ".rule.json"
  | each {|r|
      let f = ($fired | get --optional $r.id)
      {
        id: $r.id
        made_at: $r.made_at
        subject: $r.subject
        symbol: $r.symbol
        condition: $"($r.condition) ($r.level)"
        node: $r.node
        state: (if $f != null { "fired" } else if ($r.node != null and $r.node > (today)) { "pending" } else { "armed" })
        fired_at: ($f | get --optional fired_at)
        observed: ($f | get --optional observed)
      }
    }
  | sort-by made_at --reverse
}

# evaluate every rule that has not fired yet. this is the daily node.
#
# a rule that fires is recorded, and a rule that does not is left alone — so the same
# condition does not raise the same alert every morning until it becomes noise.
export def check []: nothing -> any {
  let fired = (all ".fired.json" | get id)
  let live = (all ".rule.json" | where {|r| not ($r.id in $fired) })
  if ($live | is-empty) { return [] }

  $live | each {|r|
    if $r.node != null and $r.node > (today) {
      {id: $r.id, subject: $r.subject, state: "pending", because: $"node ($r.node) has not arrived", observed: null}
    } else {
      let o = (observe $r.symbol $r.via)
      if $o == null {
        # no observation is NOT a false: it is an absence, and it is reported as one
        {id: $r.id, subject: $r.subject, state: "unknown", because: $"no observation for ($r.symbol) via ($r.via)", observed: null}
      } else {
        let met = (if $r.condition == "above" { $o.value > $r.level } else { $o.value < $r.level })
        if $met {
          let f = {
            id: $r.id
            subject: $r.subject
            fired_at: (date now | format date "%Y-%m-%dT%H:%M:%S")
            condition: $r.condition
            level: $r.level
            observed: $o.value
            observed_period: $o.period
            observed_source: $o.source
            note: $r.note
          }
          $f | save -f (fired-path $r.id)
          # every state carries `because`, so the result is one table whatever happened
          $f | insert state "fired" | insert because $"($o.value) is ($r.condition) ($r.level)"
        } else {
          {id: $r.id, subject: $r.subject, state: "armed", because: $"($o.value) is not ($r.condition) ($r.level)", observed: $o.value}
        }
      }
    }
  }
}

# drop everything. destructive; here for test isolation, not for use.
export def purge []: nothing -> string {
  if not ((store-dir) | path exists) { return "nothing to purge" }
  let files = (glob (store-dir | path join "*.json"))
  if ($files | is-empty) { return "nothing to purge" }
  rm -f ...$files
  $"purged ($files | length) files from (store-dir)"
}
