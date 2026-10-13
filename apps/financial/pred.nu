# pred.nu — what was believed, and when. append-only.
#
#   use pred.nu
#
#   pred record --subject "UST:10 Yr" --at 5.24 --direction up --horizon 2026-10-31 \
#               --confidence 0.62 --rationale "policy rate held, term premium thick" \
#               --inputs [[source url fetched_at]; [treasury-curve "https://…" "2026-10-12T09:00:00"]]
#   pred list
#   pred score pred-… --actual 5.31
#   pred calibration
#
# ── the one rule ──
# a prediction is NEVER modified. revising one writes a NEW record carrying `supersedes`, so
# yesterday's belief stays exactly as it was. this is the whole point: overwriting destroys
# the only thing that can tell you whether any of this works — what you believed at a time
# when you could not yet know. a system that revises its own history cannot be scored.
#
# scoring writes a SEPARATE file for the same reason. the outcome is a fact about the world
# recorded later; the prediction is a fact about you recorded earlier. merging them would
# erase the gap between the two, which is the only gap worth measuring.
#
# ── why `at` is required for a direction ──
# "I think it goes up" is not scoreable without the level it was said relative to. a
# prediction that cannot be scored is a mood, so a direction without a baseline is refused.

const DIR_NAME = "nu-agent-predictions"

def now-epoch []: nothing -> int {
  (date now | format date "%s") | into int
}

def store-dir []: nothing -> path {
  let override = ($env.NU_AGENT_PRED_DIR? | default "")
  if ($override | is-empty) { $nu.data-dir | path join $DIR_NAME } else { $override | path expand }
}

def pred-path [id: string]: nothing -> path { store-dir | path join $"($id).json" }
def score-path [id: string]: nothing -> path { store-dir | path join $"($id).scored.json" }

def all-files []: nothing -> list<path> {
  if ((store-dir) | path exists) { glob (store-dir | path join "*.json") } else { [] }
}

def predictions []: nothing -> list<record> {
  all-files | where {|p| not (($p | path parse | get stem) | str ends-with ".scored") }
  | each {|p| try { open $p } catch { null } } | compact
}

def outcomes []: nothing -> record {
  all-files | where {|p| (($p | path parse | get stem) | str ends-with ".scored") }
  | each {|p| try { open $p } catch { null } } | compact
  | reduce --fold {} {|o, acc| $acc | upsert $o.id $o }
}

# ── commands ──

# write a prediction. never updates one; use --supersedes to revise, which writes a new record
# naming the old one.
export def record [
  --subject: string        # what it is about, matching the series id where there is one
  --at: float              # the level now, which a direction is relative to
  --direction: string      # up | down | flat — required with --at
  --horizon: string        # the period it applies to, e.g. 2026-10-31 or 2026-Q4 (required)
  --value: float           # a point forecast, when the claim is a level rather than a direction
  --confidence: float      # 0..1
  --rationale: string      # why, in prose
  --inputs: list<record>   # provenance: [[source url fetched_at]; …]
  --supersedes: string     # the id of the prediction this revises
  --made-by: string = "agent"
]: nothing -> record {
  if $horizon == null { error make { msg: "--horizon is required: an unscored prediction is a mood, and an undated one can never be scored" } }
  if $subject == null { error make { msg: "--subject is required" } }
  if $direction == null and $value == null {
    error make { msg: "give --direction (with --at) or --value — a prediction with neither asserts nothing" }
  }
  if $direction != null and $at == null {
    error make { msg: "--direction needs --at: 'it goes up' is not scoreable without the level it was said relative to" }
  }
  if $direction != null and not ($direction in ["up" "down" "flat"]) {
    error make { msg: $"direction must be up, down or flat, got '($direction)'" }
  }
  if $confidence != null and ($confidence < 0.0 or $confidence > 1.0) {
    error make { msg: $"confidence must be in [0, 1], got ($confidence)" }
  }
  if $supersedes != null and not ((pred-path $supersedes) | path exists) {
    error make { msg: $"nothing to supersede: no prediction ($supersedes)" }
  }

  mkdir (store-dir)
  let e = (now-epoch)
  let id = $"pred-($e)-(random int 1000..9999)"
  let p = {
    id: $id
    made_at: (date now | format date "%Y-%m-%dT%H:%M:%S")
    made_epoch: $e
    made_by: $made_by
    subject: $subject
    horizon: $horizon
    at: $at
    direction: $direction
    value: $value
    confidence: $confidence
    rationale: $rationale
    inputs: ($inputs | default [])
    supersedes: $supersedes
  }
  $p | save -f (pred-path $id)
  $p
}

# the index: every prediction ever made, newest first, with its outcome if it has one
export def list []: nothing -> any {
  let outs = (outcomes)
  predictions
  | each {|p|
      let o = ($outs | get --optional $p.id)
      {
        id: $p.id
        made_at: $p.made_at
        subject: $p.subject
        horizon: $p.horizon
        at: $p.at
        direction: $p.direction
        value: $p.value
        confidence: $p.confidence
        supersedes: $p.supersedes
        scored: ($o != null)
      }
    }
  | sort-by made_at --reverse
}

# file what actually happened. writes a separate record; the prediction is untouched.
export def score [
  id: string
  --actual: float          # the level the horizon closed at
  --note: string
]: nothing -> record {
  if not ((pred-path $id) | path exists) {
    error make { msg: $"no prediction ($id)" }
  }
  if $actual == null { error make { msg: "--actual is required" } }
  let p = (open (pred-path $id))
  let hit = (
    if $p.direction != null {
      # a direction is scored against the level it was said at, not against a threshold
      if $p.direction == "flat" { ($actual - $p.at | math abs) < 0.0001 } else if $p.direction == "up" { $actual > $p.at } else { $actual < $p.at }
    } else { null }
  )
  let o = {
    id: $id
    scored_at: (date now | format date "%Y-%m-%dT%H:%M:%S")
    subject: $p.subject
    horizon: $p.horizon
    at: $p.at
    direction: $p.direction
    value: $p.value
    confidence: $p.confidence
    actual: $actual
    hit: $hit
    # how far off a point forecast was, in the series' own units
    error: (if $p.value == null { null } else { $actual - $p.value })
    note: $note
  }
  $o | save -f (score-path $id)
  $o
}

# THE number, and the only one that summarises the whole apparatus: when this system said
# 70%, was it right 70% of the time? a single hit rate hides that; the buckets are the point.
export def calibration []: nothing -> any {
  let outs = (outcomes | values)
  if ($outs | is-empty) { return {scored: 0, note: "nothing scored yet — this is what months of archived predictions are for"} }

  let directional = ($outs | where {|o| $o.hit != null })
  let buckets = (
    [0.5 0.6 0.7 0.8 0.9]
    | each {|lo|
        let hi = ($lo + 0.1)
        let in_b = ($directional | where {|o| $o.confidence != null and $o.confidence >= $lo and $o.confidence < $hi })
        if ($in_b | is-empty) { null } else {
          {
            stated: $"($lo)–($hi)"
            n: ($in_b | length)
            hit_rate: ((($in_b | where hit | length) | into float) / (($in_b | length) | into float))
            mean_stated: (($in_b | get confidence | math avg))
          }
        }
      }
    | compact
  )
  let point = ($outs | where {|o| $o.error != null })

  {
    scored: ($outs | length)
    directional: ($directional | length)
    directional_hit_rate: (if ($directional | is-empty) { null } else { (($directional | where hit | length) | into float) / (($directional | length) | into float) })
    by_stated_confidence: $buckets
    point_forecasts: (if ($point | is-empty) { null } else {
      {
        n: ($point | length)
        mean_error: ($point | get error | math avg)
        mean_absolute_error: ($point | each {|o| $o.error | math abs } | math avg)
      }
    })
    definition: {
      calibration: "per bucket of stated confidence, the share that were right. a well-calibrated 0.7 bucket hits about 0.7 — above means underconfident, below means overconfident"
      directional: "scored against the level recorded at the time (`at`), never against a threshold chosen afterwards"
      mean_error: "signed, so a persistent bias shows up as a non-zero mean rather than being hidden by the absolute value"
    }
  }
}

# the predictions whose horizon has passed and that nobody has scored
export def due []: nothing -> any {
  let outs = (outcomes)
  let today = (date now | format date "%Y-%m-%d")
  predictions
  | where {|p| ($outs | get --optional $p.id) == null }
  | where {|p| $p.horizon < $today }
  | each {|p| {id: $p.id, subject: $p.subject, horizon: $p.horizon, direction: $p.direction, at: $p.at, confidence: $p.confidence} }
  | sort-by horizon
}

# drop every stored prediction. destructive, and here for test isolation rather than use:
# the archive is the point.
export def purge []: nothing -> string {
  let files = (all-files)
  if ($files | is-empty) { return "nothing to purge" }
  rm -f ...$files
  $"purged ($files | length) files from (store-dir)"
}
