#!/usr/bin/env nu
# pred.nu — the append-only prediction record
#
# hermetic: the store is pointed at a temp directory. the invariants under test are the ones
# that make the archive worth keeping at all — nothing is overwritten, scoring is separate
# from predicting, and a direction is scored against the level it was said at.

use ./harness.nu *
use ./../apps/financial/pred.nu

$env.NU_AGENT_PRED_DIR = ($nu.temp-dir | path join $"nu-agent-pred-test-(random int 100000..999999)")
mkdir $env.NU_AGENT_PRED_DIR

let results = [
  # ── what a prediction must carry ──
  (case "record: a prediction is written with the moment it was made" {
    let p = (pred record --subject "UST:10 Yr" --at 5.24 --direction up --horizon 2026-10-31 --confidence 0.62)
    (eq "record: a prediction is written with the moment it was made" [$p.subject $p.at $p.direction $p.confidence] ["UST:10 Yr" 5.24 "up" 0.62])
  })

  (case "record: a horizon is required, because an undated claim can never be scored" {
    (throws "record: a horizon is required, because an undated claim can never be scored" {
      pred record --subject "X" --value 1.0
    })
  })

  (case "record: a direction without the level it was said at is refused" {
    # "it goes up" is not scoreable without a baseline, and an unscoreable prediction is a mood
    (throws "record: a direction without the level it was said at is refused" {
      pred record --subject "X" --direction up --horizon 2026-10-31
    })
  })

  (case "record: neither a direction nor a value asserts nothing, and is refused" {
    (throws "record: neither a direction nor a value asserts nothing, and is refused" {
      pred record --subject "X" --horizon 2026-10-31
    })
  })

  (case "record: a confidence outside [0,1] is refused" {
    (throws "record: a confidence outside [0,1] is refused" {
      pred record --subject "X" --value 1.0 --horizon 2026-10-31 --confidence 1.4
    })
  })

  (case "record: provenance is carried, so 'what did you know then' has an answer" {
    let p = (pred record --subject "X" --value 1.0 --horizon 2026-10-31 --inputs [[source url]; [treasury-curve "https://example.test/c"]])
    (eq "record: provenance is carried, so 'what did you know then' has an answer" ($p.inputs | first | get source) "treasury-curve")
  })

  # ── the invariant: nothing is overwritten ──
  (case "supersede: revising writes a NEW record and leaves the old one byte-identical" {
    let first = (pred record --subject "SSE" --at 3797.24 --direction up --horizon 2026-10-31 --confidence 0.55)
    let before = (open ($env.NU_AGENT_PRED_DIR | path join $"($first.id).json"))
    let second = (pred record --subject "SSE" --at 3797.24 --direction down --horizon 2026-10-31 --confidence 0.7 --supersedes $first.id)
    let after = (open ($env.NU_AGENT_PRED_DIR | path join $"($first.id).json"))
    (eq "supersede: revising writes a NEW record and leaves the old one byte-identical" [
      ($second.supersedes == $first.id) ($after == $before) (($first.id) != ($second.id))
    ] [true true true])
  })

  (case "supersede: superseding something that does not exist is refused" {
    (throws "supersede: superseding something that does not exist is refused" {
      pred record --subject "X" --value 1.0 --horizon 2026-10-31 --supersedes no-such-id
    })
  })

  # ── scoring is separate from predicting ──
  (case "score: the outcome is a separate file; the prediction is untouched" {
    let p = (pred record --subject "GOLD" --at 100.0 --direction up --horizon 2026-01-31 --confidence 0.6)
    let before = (open ($env.NU_AGENT_PRED_DIR | path join $"($p.id).json"))
    let o = (pred score $p.id --actual 105.0)
    let after = (open ($env.NU_AGENT_PRED_DIR | path join $"($p.id).json"))
    (eq "score: the outcome is a separate file; the prediction is untouched" [
      ($o.hit) ($after == $before) (($env.NU_AGENT_PRED_DIR | path join $"($p.id).scored.json") | path exists)
    ] [true true true])
  })

  (case "score: a direction is scored against the level it was said at" {
    let up = (pred record --subject "A" --at 10.0 --direction up --horizon 2026-01-31)
    let down = (pred record --subject "B" --at 10.0 --direction down --horizon 2026-01-31)
    (eq "score: a direction is scored against the level it was said at" [
      (pred score $up.id --actual 11.0 | get hit) (pred score $down.id --actual 11.0 | get hit)
    ] [true false])
  })

  (case "score: a point forecast records its signed error, not just a hit" {
    let p = (pred record --subject "C" --value 5.0 --horizon 2026-01-31)
    (is-true "score: a point forecast records its signed error, not just a hit" (((pred score $p.id --actual 5.4 | get error) - 0.4 | math abs) < 1e-9))
  })

  (case "score: scoring an unknown id is refused" {
    (throws "score: scoring an unknown id is refused" { pred score no-such-id --actual 1.0 })
  })

  # ── the index, the queue and the number ──
  (case "list: every prediction is listed, newest first, with its scored flag" {
    let l = (pred list | where subject == "UST:10 Yr" | first)
    (eq "list: every prediction is listed, newest first, with its scored flag" [$l.subject $l.scored] ["UST:10 Yr" false])
  })

  (case "list: a scored prediction is marked as such" {
    (is-true "list: a scored prediction is marked as such" ((pred list | where scored | length) > 0))
  })

  (case "due: picks up the ones whose horizon has passed and nobody scored" {
    # the daily loop's queue: a horizon in the past with no outcome filed. made explicit
    # here rather than assumed, because every past-horizon prediction above was scored.
    pred record --subject "OVERDUE" --value 1.0 --horizon 2020-01-31 | ignore
    let d = (pred due)
    (is-true "due: picks up the ones whose horizon has passed and nobody scored" (((($d | length) > 0)) and ($d | all {|x| $x.horizon < (date now | format date "%Y-%m-%d")})))
  })

  (case "due: a future horizon is not due" {
    let p = (pred record --subject "FUTURE" --value 1.0 --horizon 2099-12-31)
    (is-true "due: a future horizon is not due" ((pred due | where id == $p.id | length) == 0))
  })

  (case "calibration: reports per bucket of STATED confidence, which is the whole point" {
    # a single hit rate hides overconfidence; the buckets are what show it
    let c = (pred calibration)
    (is-true "calibration: reports per bucket of STATED confidence, which is the whole point" (($c.scored > 0) and (($c.by_stated_confidence | first | get stated) | is-not-empty)))
  })

  (case "calibration: every bucket carries both the stated and the realised rate" {
    # the comparison is the product: stated 0.6 vs realised 0.4 is overconfidence made visible
    let b = (pred calibration | get by_stated_confidence | first)
    (eq "calibration: every bucket carries both the stated and the realised rate" [($b.n > 0) ($b.mean_stated | describe) ($b.hit_rate | describe)] [true "float" "float"])
  })

  (case "calibration: an empty archive says so instead of reporting zero calibration" {
    pred purge | ignore
    (has "calibration: an empty archive says so instead of reporting zero calibration" (pred calibration | get note) "months of archived predictions")
  })
]

emit $results
