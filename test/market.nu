#!/usr/bin/env nu
# market.nu — the market data layer's parsers, replayed from canned payloads
#
# hermetic, like test/macro.nu: the parsers hold the real logic and the shapes that bite are
# the ones worth replaying — a US date format, a JavaScript assignment instead of JSON, two
# different field layouts behind one endpoint, and numbers sent as strings.

use ./harness.nu *
use ./../apps/financial/market-parse.nu

# the Treasury CSV arrives already parsed by nu into a table: one row per date, one column
# per tenor, and the date in MM/DD/YYYY
let curve_rows = [
  {Date: "10/09/2026", "1 Mo": 3.9, "2 Yr": 4.8, "10 Yr": 5.24, "30 Yr": 5.4}
  {Date: "10/08/2026", "1 Mo": 3.88, "2 Yr": 4.75, "10 Yr": 5.22, "30 Yr": 5.38}
]

let kline = [
  {day: "2026-10-08", open: "3838.977", high: "3864.118", low: "3795.374", close: "3811.904", volume: "48220168500"}
  {day: "2026-10-09", open: "3811.904", high: "3830.0", low: "3800.0", close: "3820.5", volume: "41000000000"}
]

# measured: hq.sinajs.cn answers with a JavaScript assignment, not JSON, and the body has a
# different layout for equities than for FX
let quote_equity = "var hq_str_sh000001=\"上证指数,3806.9786,3813.7913,3797.2424,3828.2162,3790.9954,0,0,461448981,714909910722,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2026-10-12,16:19:55,00,\";"
let quote_fx = "var hq_str_fx_susdcnh=\"19:07:03,6.694600,6.694700,6.692700,44,6.694100,6.694700,6.690300,6.694600,离岸人民币（香港）,0.030000,0.001900,0.0006573,,6.995700,6.690700,,2026-10-12\";"
let quote_empty = "var hq_str_USDCNH=\"\";"

let fx_payload = {amount: 1.0, base: "USD", date: "2026-10-09", rates: {CNY: 6.6921}}

let results = [
  # ── the US Treasury curve ──
  (case "curve: one record per (date, tenor)" {
    let r = (market-parse treasury-curve $curve_rows "u")
    (eq "curve: one record per (date, tenor)" [($r | length) ($r | get series | uniq | sort)] [8 ["UST:1 Mo" "UST:10 Yr" "UST:2 Yr" "UST:30 Yr"]])
  })

  (case "curve: the MM/DD/YYYY date is rewritten to ISO, not handed to the date parser" {
    # measured: nu reads 10/09 as the 10th of September. the Treasury is the one source here
    # that publishes US-format dates, so the rewrite is explicit rather than hoped for.
    let r = (market-parse treasury-curve $curve_rows "u")
    (eq "curve: the MM/DD/YYYY date is rewritten to ISO, not handed to the date parser" ($r | where series == "UST:10 Yr" | get reference_period) ["2026-10-09" "2026-10-08"])
  })

  (case "curve: the tenors are the columns, taken as published" {
    let r = (market-parse treasury-curve $curve_rows "u")
    (eq "curve: the tenors are the columns, taken as published" ($r | where series == "UST:10 Yr" | first | get value) 5.24)
  })

  (case "curve: units are percent, stated per record" {
    let r = (market-parse treasury-curve $curve_rows "u")
    (eq "curve: units are percent, stated per record" ($r | first | get units) "percent")
  })

  # ── Sina K-line ──
  (case "kline: only the requested fields become series" {
    # OHLCV is five series, so asking for one must not silently produce five
    let r = (market-parse sina-kline $kline "sh000001" "u" ["close"])
    (eq "kline: only the requested fields become series" ($r | get series | uniq) ["sh000001:close"])
  })

  (case "kline: the series id is symbol:field, so a frame stays one series" {
    let r = (market-parse sina-kline $kline "sh000001" "u" ["close" "volume"])
    (eq "kline: the series id is symbol:field, so a frame stays one series" ($r | get series | uniq | sort) ["sh000001:close" "sh000001:volume"])
  })

  (case "kline: numeric strings become numbers" {
    let r = (market-parse sina-kline $kline "sh000001" "u" ["close"])
    (eq "kline: numeric strings become numbers" ($r | get value) [3811.904 3820.5])
  })

  (case "kline: volume gets its own unit rather than the price unit" {
    # shares and index points are not the same quantity; labelling both "price" would let a
    # frame mix them and read as one series
    let r = (market-parse sina-kline $kline "sh000001" "u" ["close" "volume"])
    (eq "kline: volume gets its own unit rather than the price unit" [
      ($r | where series == "sh000001:close" | first | get units)
      ($r | where series == "sh000001:volume" | first | get units)
    ] ["the instrument's own quote unit" "shares"])
  })

  (case "kline: an unknown symbol raises rather than returning nothing" {
    (throws "kline: an unknown symbol raises rather than returning nothing" { market-parse sina-kline [] "sh999999" "u" ["close"] })
  })

  # ── Sina quote ──
  (case "quote: the JavaScript assignment is unwrapped and the equity layout read" {
    let r = (market-parse sina-quote $quote_equity "sh000001" "u")
    (eq "quote: the JavaScript assignment is unwrapped and the equity layout read" ($r | where series == "sh000001:close" | first | get value) 3797.2424)
  })

  (case "quote: an equity snapshot yields the five price fields it carries" {
    let r = (market-parse sina-quote $quote_equity "sh000001" "u")
    (eq "quote: an equity snapshot yields the five price fields it carries" ($r | get series | sort) [
      "sh000001:close" "sh000001:high" "sh000001:low" "sh000001:open" "sh000001:prev_close"
    ])
  })

  (case "quote: FX uses a different field layout, and says which position it read" {
    # the FX body is undocumented; the parser takes position 8 and RECORDS that choice, so
    # the claim can be checked instead of trusted
    let r = (market-parse sina-quote $quote_fx "fx_susdcnh" "u")
    (eq "quote: FX uses a different field layout, and says which position it read" [($r | first | get value) ($r | first | get field_position)] [6.6946 8])
  })

  (case "quote: an empty body raises instead of yielding a null value" {
    (throws "quote: an empty body raises instead of yielding a null value" { market-parse sina-quote $quote_empty "USDCNH" "u" })
  })

  # ── frankfurter ──
  (case "fx: each rate becomes a record, keyed base/quote" {
    let r = (market-parse frankfurter $fx_payload "u")
    (eq "fx: each rate becomes a record, keyed base/quote" [($r | first | get series) ($r | first | get value)] ["USD/CNY" 6.6921])
  })

  (case "fx: the fixing date is the reference period" {
    (eq "fx: the fixing date is the reference period" (market-parse frankfurter $fx_payload "u" | first | get reference_period) "2026-10-09")
  })

  (case "fx: units state the quote direction, which is trivially easy to invert" {
    (has "fx: units state the quote direction, which is trivially easy to invert" (market-parse frankfurter $fx_payload "u" | first | get units) "per one unit of the base")
  })

  # ── the contract every market record shares with every macro record ──
  (case "record: a market record and a macro record have the same fields" {
    # the point of one record shape: nothing downstream needs to know which door a datum
    # came in through
    let m = (market-parse frankfurter $fx_payload "u" | first | columns | sort)
    let want = ["definition" "reference_period" "retrieved_at" "series" "source" "source_url" "units" "value" "vintage"]
    (eq "record: a market record and a macro record have the same fields" $m $want)
  })
]

emit $results
