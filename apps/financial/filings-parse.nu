# filings-parse.nu — the pure half of the filings layer
#
# EDGAR returns facts in one shape, and the shape is unusually good: every fact carries the
# date it was FILED alongside the period it describes. that is a real vintage — the same
# period appears several times with different values as it is restated, and which one you
# see is decided by when you ask.

use ./macro-parse.nu

# ── EDGAR ──
#
# shape: {cik, entityName, units: {USD: [{start, end, val, form, filed, fy, fp, frame?}]}}
#
# `end` is the period the number describes; `filed` is when the company said it. storing
# `filed` as the vintage is what makes "what did they report for FY2023 in March 2024"
# answerable — and what makes a restatement visible instead of silently replacing the number
# you acted on.
export def edgar [payload: record, tag: string, url: string]: nothing -> list<record> {
  let units = ($payload.units | columns)
  if ($units | is-empty) { error make { msg: $"no units for ($tag)" } }
  $units | each {|u|
    let facts = ($payload.units | get $u)
    $facts | each {|f|
      let rec = (
        macro-parse pit $"($tag)" ($f.val | into float) $f.end $f.filed $u "edgar" $url "the period the reported figure covers"
        | insert form $f.form
        | insert fiscal ($f | get --optional fy)
        | insert fiscal_period ($f | get --optional fp)
        | insert period_start ($f | get --optional start)
      )
      $rec
    }
  } | flatten
}

# the tags an entity reports, with how many facts each carries. a company has several hundred
# of these and the names are not self-explanatory, so a listing is the only way in.
export def edgar-taxonomy [payload: record]: nothing -> table {
  let gaap = ($payload.facts | get --optional "us-gaap" | default {})
  $gaap | transpose tag body | each {|r|
    {
      tag: $r.tag
      units: ($r.body.units | columns | str join ",")
      facts: ($r.body.units | values | each {|v| $v | length } | math sum)
    }
  } | sort-by tag
}

# SEC's ticker → CIK map. the two namespaces are unrelated and this is the only bridge.
export def edgar-cik [payload: record, ticker: string]: nothing -> string {
  let t = ($ticker | str uppercase)
  let hit = ($payload | transpose k v | where {|r| ($r.v.ticker | str uppercase) == $t } | first)
  if $hit == null { error make { msg: $"no CIK for ticker ($ticker) — SEC lists it under a different symbol, or it is not a US registrant" } }
  $"($hit.v.cik_str)"
}

# ── the point-in-time cut ──
#
# given every vintage of every period, answer what was known on a date. this is the whole
# reason `filed` is stored, and it is the difference between a backtest and a fantasy.
export def as-of [records: list<record>, date: any]: nothing -> list<record> {
  if $date == null { return $records }
  let known = ($records | where {|r| $r.vintage <= $date })
  if ($known | is-empty) { return [] }
  # per period, the latest vintage that was already public on that date
  $known
  | group-by reference_period
  | transpose period rows
  | each {|g| $g.rows | sort-by vintage | last }
}
