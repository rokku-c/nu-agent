# market-parse.nu — the pure half of the market data layer
#
# mirrors macro-parse.nu: payloads in, point-in-time records out, no network. it shares
# macro-parse.nu's `pit` and `period`, because a price and a macro indicator are the same
# kind of record once stored — which is the entire point of having one record shape.

use ./macro-parse.nu

# a number from whatever the source sent. every one of these APIs sends numbers as
# strings, blanks as "", and sometimes omits the key entirely; all three mean the same
# thing, and none of them mean zero.
def num [x: any]: nothing -> any {
  if $x == null { return null }
  if (($x | into string) | str trim | is-empty) { return null }
  $x | into float
}

# ── US Treasury: the daily yield curve ──
#
# the CSV arrives already parsed by nu into a table — one row per date, one column per
# tenor — so what has to be produced is the transpose: one record per (date, tenor).
#
# note the date format: the Treasury publishes MM/DD/YYYY. that is the one shape nu's own
# date parse would silently misread (10/09 as the 10th of September), so it is rewritten
# here and not handed over.
export def treasury-curve [rows: table, url: string]: nothing -> list<record> {
  let tenors = (($rows | first | columns) | where {|c| $c != "Date" })
  $rows
  | each {|r|
      let mmddyyyy = ($r.Date | into string)
      let parts = ($mmddyyyy | split row "/")
      if ($parts | length) != 3 {
        error make { msg: $"cannot read the Treasury date '($mmddyyyy)' — expected MM/DD/YYYY" }
      }
      let d = $"($parts | get 2)-($parts | get 0)-($parts | get 1)"
      $tenors | each {|t|
        macro-parse pit $"UST:($t)" (num ($r | get $t)) $d null "percent" "treasury-curve" $url "one row per business day"
      }
    }
  | flatten
}

# ── Sina: daily K-line history ──
#
# OHLCV is several series, not one, so it becomes several records per date — exactly the way
# the Treasury curve's tenors do. that keeps one series per record, which is what `frame` and
# `state` require to mean anything: a frame mixing a close with a volume would place two
# different quantities on one axis.
export def sina-kline [payload: list, symbol: string, url: string, fields: list<string>]: nothing -> list<record> {
  if ($payload | is-empty) {
    error make { msg: $"sina returned no rows for ($symbol) — check the symbol (sh000001, sz399001, …)" }
  }
  $payload
  | each {|r|
      $fields | each {|f|
        macro-parse pit $"($symbol):($f)" (num ($r | get --optional $f)) $r.day null (if $f == "volume" { "shares" } else { "the instrument's own quote unit" }) "sina-kline" $url "one row per trading day"
      }
    }
  | flatten
}

# ── Sina: the realtime snapshot ──
#
# the payload is not JSON and not one format: `hq.sinajs.cn` answers with a JavaScript
# assignment whose comma-separated body has DIFFERENT layouts for equities and for FX.
# measured against the live service:
#
#   equity  var hq_str_sh000001="上证指数,open,prev_close,CURRENT,high,low,…"
#   fx      var hq_str_fx_susdcnh="time,bid,ask,…,RATE,…,name,…"
#
# so the layout is chosen by the symbol prefix, and which field was read is written into the
# definition — the FX layout is undocumented and this parser takes position 8 for it, which
# is a claim a reader can check rather than a fact they have to trust.
export def sina-quote [text: string, symbol: string, url: string]: nothing -> list<record> {
  let body = (
    $text
    | str replace -r '^[^"]*"' ''
    | str replace -r '";?\s*$' ''
    | str trim
  )
  if ($body | is-empty) {
    error make { msg: $"sina returned nothing for ($symbol) — the symbol is probably not one `hq.sinajs.cn` serves" }
  }
  let f = ($body | split row ",")

  if ($symbol | str starts-with "fx_") {
    let rate = (num ($f | get --optional 8))
    let day = ($f | get --optional 17 | default "")
    [ (macro-parse pit $symbol $rate $day null "the pair's quote convention" "sina-quote" $url "a live snapshot, not a fixing" | insert field_position 8) ]
  } else {
    [
      {f: "close", i: 3}
      {f: "open", i: 1}
      {f: "prev_close", i: 2}
      {f: "high", i: 4}
      {f: "low", i: 5}
    ]
    | each {|s|
        let day = ($f | get --optional 30 | default "")
        let v = (num ($f | get --optional $s.i))
        macro-parse pit $"($symbol):($s.f)" $v $day null (if $s.f == "volume" { "shares" } else { "the instrument's own quote unit" }) "sina-quote" $url "a live snapshot taken during the session"
      }
  }
}

# ── frankfurter: ECB reference rates ──
export def frankfurter [payload: record, url: string]: nothing -> list<record> {
  $payload.rates
  | transpose pair rate
  | each {|r|
      macro-parse pit $"($payload.base)/($r.pair)" (num $r.rate) $payload.date null "units of the quote currency per one unit of the base" "frankfurter" $url "the ECB reference fixing, published once per business day"
    }
}
