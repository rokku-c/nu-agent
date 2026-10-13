#!/usr/bin/env nu
# filings.nu — the EDGAR parsers, and the point-in-time cut
#
# hermetic: filings-parse.nu is pure, so the vintage logic — the whole reason this layer
# exists — is tested against canned facts rather than against a live filing.

use ./harness.nu *
use ./../apps/financial/filings-parse.nu

# one period, filed twice: the FY2017 figure as first reported, and as restated a year later.
# this is the shape the whole layer exists to keep rather than collapse.
let facts = {units: {USD: [
  {start: "2016-10-01", end: "2017-09-30", val: 229234000000, form: "10-K", filed: "2017-11-03", fy: 2017, fp: "FY"}
  {start: "2016-10-01", end: "2017-09-30", val: 228000000000, form: "10-K", filed: "2018-11-05", fy: 2018, fp: "FY"}
  {start: "2017-10-01", end: "2018-09-29", val: 265595000000, form: "10-K", filed: "2018-11-05", fy: 2018, fp: "FY"}
  {start: "2018-06-30", end: "2018-09-29", val: 62900000000, form: "10-K", filed: "2018-11-05", fy: 2018, fp: "FY"}
]}}

let ciks = {"0": {cik_str: 320193, ticker: "AAPL", title: "Apple Inc."} "1": {cik_str: 789019, ticker: "MSFT", title: "Microsoft"}}

let results = [
  # ── the parser ──
  (case "edgar: every fact becomes a record with its period and its filing date" {
    let r = (filings-parse edgar $facts "Revenues" "u")
    (eq "edgar: every fact becomes a record with its period and its filing date" [
      ($r | length) ($r | first | get reference_period) ($r | first | get vintage)
    ] [4 "2017-09-30" "2017-11-03"])
  })

  (case "edgar: the unit becomes the units field, so a dollar and a share count never mix" {
    (eq "edgar: the unit becomes the units field, so a dollar and a share count never mix" (filings-parse edgar $facts "Revenues" "u" | first | get units) "USD")
  })

  (case "edgar: the filing form and fiscal period ride along" {
    let r = (filings-parse edgar $facts "Revenues" "u" | first)
    (eq "edgar: the filing form and fiscal period ride along" [$r.form $r.fiscal $r.fiscal_period] ["10-K" 2017 "FY"])
  })

  # ── the point-in-time cut: the reason any of this is stored ──
  (case "as-of: a date before the restatement shows the figure as FIRST reported" {
    # acting on the original number and later seeing it change is exactly the situation a
    # system that keeps only the latest value cannot represent
    let r = (filings-parse as-of (filings-parse edgar $facts "Revenues" "u") "2017-12-31")
    (eq "as-of: a date before the restatement shows the figure as FIRST reported" ($r | where reference_period == "2017-09-30" | first | get value) 229234000000.0)
  })

  (case "as-of: a date after the restatement shows the restated figure" {
    let r = (filings-parse as-of (filings-parse edgar $facts "Revenues" "u") "2019-01-01")
    (eq "as-of: a date after the restatement shows the restated figure" ($r | where reference_period == "2017-09-30" | first | get value) 228000000000.0)
  })

  (case "as-of: exactly one record per period survives the cut" {
    # the cut picks the latest vintage already public, not every vintage — otherwise the
    # caller gets two answers to one question
    let r = (filings-parse as-of (filings-parse edgar $facts "Revenues" "u") "2019-01-01")
    (eq "as-of: exactly one record per period survives the cut" ($r | get reference_period | length) ($r | get reference_period | uniq | length))
  })

  (case "as-of: the restatement stays visible when no cut is asked for" {
    let r = (filings-parse as-of (filings-parse edgar $facts "Revenues" "u") null)
    (eq "as-of: the restatement stays visible when no cut is asked for" ($r | where reference_period == "2017-09-30" | length) 2)
  })

  (case "as-of: a date before anything was filed yields nothing, not the earliest guess" {
    (eq "as-of: a date before anything was filed yields nothing, not the earliest guess" (filings-parse as-of (filings-parse edgar $facts "Revenues" "u") "2010-01-01") [])
  })

  # ── the ticker bridge ──
  (case "cik: a ticker maps to the SEC's own numeric namespace" {
    (eq "cik: a ticker maps to the SEC's own numeric namespace" (filings-parse edgar-cik $ciks "aapl") "320193")
  })

  (case "cik: an unknown ticker raises rather than returning an empty CIK" {
    # an empty CIK would build a URL that 404s and reads like "this company files nothing"
    (throws "cik: an unknown ticker raises rather than returning an empty CIK" { filings-parse edgar-cik $ciks "NOSUCH" })
  })

  # ── the taxonomy ──
  (case "taxonomy: the tags are listed with how many facts each carries" {
    let f = {facts: {"us-gaap": {Revenues: {units: {USD: [1 2 3]}}, Assets: {units: {USD: [1]}}}}}
    (eq "taxonomy: the tags are listed with how many facts each carries" (filings-parse edgar-taxonomy $f | where tag == "Revenues" | first | get facts) 3)
  })
]

emit $results
