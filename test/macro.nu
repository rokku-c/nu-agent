#!/usr/bin/env nu
# macro.nu — the data layer: point-in-time records from canned payloads, plus transcription
#
# hermetic on purpose, the way test/stream.nu is: the parsers are the half with real logic,
# and replaying a recorded payload exercises the shapes that matter (a missing period, a
# value that is a string, a positional index) without needing a key or a network. the live
# calls are covered by the e2e suite's neighbours — a fetch failure here would be a
# transport failure, not a parsing one.

use ./harness.nu *
use ./../apps/financial/macro-parse.nu

# ── canned payloads, shaped exactly as each source sends them ──

# FRED sends numbers as STRINGS and "." for a missing period
let fred_payload = {
  units: "Billions of Chained 2017 Dollars"
  observations: [
    {realtime_start: "2024-07-25", realtime_end: "2025-09-25", date: "2024-04-01", value: "23400.1"}
    {realtime_start: "2024-07-25", realtime_end: "2025-09-25", date: "2024-01-01", value: "23100.5"}
    {realtime_start: "2024-07-25", realtime_end: "2025-09-25", date: "2023-10-01", value: "."}
  ]
}

# World Bank wraps its rows in a two-element list: [meta, rows]
let wb_payload = [
  {page: 1, pages: 1, per_page: 3, total: 3}
  [
    {indicator: {id: "NY.GDP.MKTP.CD", value: "GDP (current US$)"}, country: {id: "CN", value: "China"}, date: "2024", value: 18729668435848, unit: "", decimal: 0}
    {indicator: {id: "NY.GDP.MKTP.CD", value: "GDP (current US$)"}, country: {id: "CN", value: "China"}, date: "2023", value: 18270356654533.2, unit: "", decimal: 0}
    {indicator: {id: "NY.GDP.MKTP.CD", value: "GDP (current US$)"}, country: {id: "CN", value: "China"}, date: "2022", value: null, unit: "", decimal: 0}
  ]
]

# Eurostat is JSON-stat: the time index maps period → position, `value` maps position → number
let es_payload = {
  updated: "2026-02-06T23:00:00+0100"
  label: "HICP - monthly data (annual rate of change)"
  dimension: {
    unit: {category: {label: {"RCH_A": "Annual rate of change"}}}
    time: {category: {index: {"2025-10": 0, "2025-11": 1, "2025-12": 2}}}
  }
  value: {"0": 2.2, "1": 2.1, "2": 2.0}
}

# ECB is SDMX-JSON 2.0: the series key is colon-separated POSITIONS into
# structure.dimensions.series, the observation dimension carries the periods, and each
# observation is [value, ...attributes] — the trailing nulls are attributes this ignores
let ecb_payload = {
  structure: {dimensions: {
    series: [
      {id: "FREQ", values: [{id: "D", name: "Daily"}]}
      {id: "REF_AREA", values: [{id: "U2", name: "Euro area"}]}
      {id: "UNIT_MEASURE", values: [{id: "PCPA", name: "Percent per annum"}]}
    ]
    observation: [{id: "TIME_PERIOD", values: [{id: "2026-10-11"} {id: "2026-10-12"}]}]
  }}
  dataSets: [{series: {"0:0:0": {observations: {"0": [2.5, 0, 0, null, null], "1": [2.5, 0, 0, null, null]}}}}]
}

# the REAL FM dataflow's dimensions — measured, and note there is no unit dimension among
# them, so a null unit is the honest answer for the ECB policy rate rather than a gap to fill
let ecb_fm_payload = {
  structure: {dimensions: {
    series: [
      {id: "FREQ", values: [{id: "D", name: "Daily"}]}
      {id: "REF_AREA", values: [{id: "U2", name: "Euro area (changing composition)"}]}
      {id: "INSTRUMENT_FM", values: [{id: "KR", name: "Key interest rate"}]}
      {id: "PROVIDER_FM_ID", values: [{id: "DFR", name: "Deposit facility - date of changes (raw data)"}]}
    ]
    observation: [{id: "TIME_PERIOD", values: [{id: "2026-10-12"}]}]
  }}
  dataSets: [{series: {"0:0:0:0": {observations: {"0": [2.5, 0, 0, null, null]}}}}]
}

let nyfed_payload = {refRates: [
  {effectiveDate: "2026-10-08", type: "EFFR", percentRate: 3.88, targetRateFrom: 3.75, targetRateTo: 4.0}
  {effectiveDate: "2026-10-07", type: "EFFR", percentRate: 3.89, targetRateFrom: 3.75, targetRateTo: 4.0}
]}

# measured: avg_interest_rates really does return several rows for one record_date, told
# apart by security_desc — the shape that makes a plain dataset name a wrong series id
let treasury_payload = {
  data: [
    {record_date: "2026-09-30", security_type_desc: "Marketable", security_desc: "Treasury Bills", avg_interest_rate_amt: "3.870"}
    {record_date: "2026-09-30", security_type_desc: "Marketable", security_desc: "Treasury Notes", avg_interest_rate_amt: "3.383"}
    {record_date: "2026-09-30", security_type_desc: "Marketable", security_desc: "Treasury Bonds", avg_interest_rate_amt: ""}
  ]
  meta: {total_count: 3}
}

let tkey = ["security_type_desc" "security_desc"]

# deliberately NOT in period order, and with a missing middle period — the two things a
# frame has to handle and the two things a source's own ordering will not protect you from
let unsorted_records = [
  {series: "X", source: "fred", value: 3.0, reference_period: "2024-03-01", vintage: null, units: "pct"}
  {series: "X", source: "fred", value: 1.0, reference_period: "2024-01-01", vintage: null, units: "pct"}
  {series: "X", source: "fred", value: null, reference_period: "2024-02-01", vintage: null, units: "pct"}
]

let results = [
  # ── FRED ──
  (case "fred: a numeric string becomes a number" {
    let r = (macro-parse fred $fred_payload "GDPC1" "u")
    (eq "fred: a numeric string becomes a number" ($r | first | get value) 23400.1)
  })

  (case "fred: \".\" becomes null, not zero and not an error" {
    # the whole point of the value field carrying null: a missing period is not a fact
    # about the world, and silently reading it as 0 would corrupt every mean downstream
    let r = (macro-parse fred $fred_payload "GDPC1" "u")
    (eq "fred: \".\" becomes null, not zero and not an error" ($r | last | get value) null)
  })

  (case "fred: realtime_start becomes the vintage" {
    let r = (macro-parse fred $fred_payload "GDPC1" "u")
    (eq "fred: realtime_start becomes the vintage" ($r | first | get vintage) "2024-07-25")
  })

  (case "fred: units come from the series metadata, not the observation" {
    let r = (macro-parse fred $fred_payload "GDPC1" "u")
    (eq "fred: units come from the series metadata, not the observation" ($r | first | get units) "Billions of Chained 2017 Dollars")
  })

  (case "fred: metadata is unpacked from the seriess array" {
    let m = (macro-parse fred-meta {seriess: [{title: "Real GDP", units: "Bil. Chained 2017 $", frequency: "Quarterly", seasonal_adjustment: "Seasonally Adjusted Annual Rate", last_updated: "2026-09-25"}]})
    (eq "fred: metadata is unpacked from the seriess array" [$m.frequency $m.units] ["Quarterly" "Bil. Chained 2017 $"])
  })

  # ── World Bank ──
  (case "worldbank: rows are unwrapped from the [meta, rows] envelope" {
    let r = (macro-parse worldbank $wb_payload "NY.GDP.MKTP.CD" "u")
    (eq "worldbank: rows are unwrapped from the [meta, rows] envelope" ($r | length) 3)
  })

  (case "worldbank: the report year is the reference period" {
    let r = (macro-parse worldbank $wb_payload "NY.GDP.MKTP.CD" "u")
    (eq "worldbank: the report year is the reference period" ($r | first | get reference_period) "2024")
  })

  (case "worldbank: vintage is null, because the source keeps no revision history" {
    # asserted rather than merely documented: a null here is a claim that the source
    # cannot answer the question, and that claim should be tested
    let r = (macro-parse worldbank $wb_payload "NY.GDP.MKTP.CD" "u")
    (eq "worldbank: vintage is null, because the source keeps no revision history" ($r | first | get vintage) null)
  })

  (case "worldbank: a null value survives as null" {
    let r = (macro-parse worldbank $wb_payload "NY.GDP.MKTP.CD" "u")
    (eq "worldbank: a null value survives as null" ($r | last | get value) null)
  })

  (case "worldbank: an empty unit string becomes null rather than \"\"" {
    let r = (macro-parse worldbank $wb_payload "NY.GDP.MKTP.CD" "u")
    (eq "worldbank: an empty unit string becomes null rather than \"\"" ($r | first | get units) null)
  })

  (case "worldbank: an error envelope raises instead of returning nothing" {
    (throws "worldbank: an error envelope raises instead of returning nothing" {
      macro-parse worldbank [{message: [{id: "120", key: "Invalid value", value: "bad"}]}] "X" "u"
    })
  })

  # ── Eurostat ──
  (case "eurostat: the positional index is inverted into periods" {
    # index is period → position and value is position → number; reading either alone
    # gives you numbers with no dates attached
    let r = (macro-parse eurostat $es_payload "prc_hicp_manr" "u")
    (eq "eurostat: the positional index is inverted into periods" ($r | get reference_period) ["2025-10" "2025-11" "2025-12"])
  })

  (case "eurostat: values line up with their periods" {
    let r = (macro-parse eurostat $es_payload "prc_hicp_manr" "u")
    (eq "eurostat: values line up with their periods" ($r | get value) [2.2 2.1 2.0])
  })

  (case "eurostat: a period present in the index but absent from value is null" {
    let p = ($es_payload | upsert value {"0": 2.2, "2": 2.0})
    let r = (macro-parse eurostat $p "prc_hicp_manr" "u")
    (eq "eurostat: a period present in the index but absent from value is null" ($r | get 1 | get value) null)
  })

  (case "eurostat: the dataset's update time stands in for a vintage" {
    let r = (macro-parse eurostat $es_payload "prc_hicp_manr" "u")
    (eq "eurostat: the dataset's update time stands in for a vintage" ($r | first | get vintage) "2026-02-06T23:00:00+0100")
  })

  (case "eurostat: the unit comes from the unit dimension" {
    # the unit is a dimension here, not a field — without this the ECB's own target
    # metric comes back with units: null, which is exactly the hole the record exists to close
    let r = (macro-parse eurostat $es_payload "prc_hicp_manr" "u")
    (eq "eurostat: the unit comes from the unit dimension" ($r | first | get units) "Annual rate of change")
  })

  (case "eurostat: a response spanning several units reports null rather than the first one" {
    # positions are flattened across dimensions, so picking one unit would silently
    # mislabel every observation belonging to the others
    let p = ($es_payload | upsert dimension.unit.category.label {"RCH_A": "Annual rate of change", "I15": "Index 2015=100"})
    let r = (macro-parse eurostat $p "prc_hicp_manr" "u")
    (eq "eurostat: a response spanning several units reports null rather than the first one" ($r | first | get units) null)
  })

  # ── ECB ──
  (case "ecb: periods come from the observation dimension" {
    let r = (macro-parse ecb $ecb_payload "K" "u")
    (eq "ecb: periods come from the observation dimension" ($r | get reference_period) ["2026-10-11" "2026-10-12"])
  })

  (case "ecb: an observation is [value, ...attributes], so the value is the first element" {
    # reading the array whole would make every value a list of five things
    let r = (macro-parse ecb $ecb_payload "K" "u")
    (eq "ecb: an observation is [value, ...attributes], so the value is the first element" ($r | first | get value) 2.5)
  })

  (case "ecb: the unit is decoded from the series key's UNIT_MEASURE position" {
    # there is no unit field anywhere in the payload: the key is positions into the
    # dimension table, and the unit is one of the labels that comes back
    let r = (macro-parse ecb $ecb_payload "K" "u")
    (eq "ecb: the unit is decoded from the series key's UNIT_MEASURE position" ($r | first | get units) "Percent per annum")
  })

  (case "ecb: key positions past the dimension table are dropped, not fatal" {
    # a real DFR key is seven positions long against a shorter dimension table
    let r = (macro-parse ecb $ecb_payload "0:0:0:0:0:0:0" "u")
    (eq "ecb: key positions past the dimension table are dropped, not fatal" ($r | first | get units) "Percent per annum")
  })

  (case "ecb: a dataflow with no unit dimension reports null, and labels what the series is" {
    # measured on the real FM dataflow: FREQ / REF_AREA / CURRENCY / PROVIDER_FM /
    # INSTRUMENT_FM / PROVIDER_FM_ID / DATA_TYPE_FM — there is no unit anywhere in it, so
    # null is the honest answer. the decoded labels are what keeps the record readable.
    let r = (macro-parse ecb $ecb_fm_payload "0:0:0:0" "u")
    (eq "ecb: a dataflow with no unit dimension reports null, and labels what the series is" (
      [($r | first | get units) ($r | first | get series_labels.INSTRUMENT_FM) ($r | first | get series_labels.PROVIDER_FM_ID)]
    ) [null "Key interest rate" "Deposit facility - date of changes (raw data)"])
  })

  (case "ecb: the decoded labels carry every dimension of the key" {
    let r = (macro-parse ecb $ecb_payload "0:0:0" "u")
    (eq "ecb: the decoded labels carry every dimension of the key" ($r | first | get series_labels | columns | sort) ["FREQ" "REF_AREA" "UNIT_MEASURE"])
  })

  # ── NY Fed ──
  (case "nyfed: the printed effective rate is the value; the date is the period" {
    let r = (macro-parse nyfed $nyfed_payload "u")
    (eq "nyfed: the printed effective rate is the value; the date is the period" [($r | first | get value) ($r | first | get reference_period)] [3.88 "2026-10-08"])
  })

  (case "nyfed: the FOMC target range rides along with the printed rate" {
    # the printed rate is an outcome; the range is the instrument the FOMC actually sets.
    # a macro record that kept only the print would lose the policy variable.
    let r = (macro-parse nyfed $nyfed_payload "u")
    (eq "nyfed: the FOMC target range rides along with the printed rate" ($r | first | get target_range) "3.75–4.0")
  })

  (case "nyfed: units are stated, not inferred from the number's size" {
    let r = (macro-parse nyfed $nyfed_payload "u")
    (eq "nyfed: units are stated, not inferred from the number's size" ($r | first | get units) "percent")
  })

  # ── US Treasury ──
  (case "treasury: a numeric string becomes a number" {
    let r = (macro-parse treasury $treasury_payload "avg_interest_rates" "avg_interest_rate_amt" "percent" $tkey "u")
    (eq "treasury: a numeric string becomes a number" ($r | first | get value) 3.87)
  })

  (case "treasury: rows sharing a record_date are distinct SERIES, not one series with two values" {
    # measured: avg_interest_rates returns several rows per date. without the discriminator
    # in the series id, four securities read as four contradictory values for one period.
    let r = (macro-parse treasury $treasury_payload "avg_interest_rates" "avg_interest_rate_amt" "percent" $tkey "u")
    (eq "treasury: rows sharing a record_date are distinct SERIES, not one series with two values" ($r | get series) [
      "avg_interest_rates:Marketable/Treasury Bills"
      "avg_interest_rates:Marketable/Treasury Notes"
      "avg_interest_rates:Marketable/Treasury Bonds"
    ])
  })

  (case "treasury: with no key columns the dataset name alone is the series" {
    let r = (macro-parse treasury $treasury_payload "avg_interest_rates" "avg_interest_rate_amt" "percent" [] "u")
    (eq "treasury: with no key columns the dataset name alone is the series" ($r | first | get series) "avg_interest_rates")
  })

  (case "treasury: record_date is the reference period" {
    let r = (macro-parse treasury $treasury_payload "avg_interest_rates" "avg_interest_rate_amt" "percent" $tkey "u")
    (eq "treasury: record_date is the reference period" ($r | first | get reference_period) "2026-09-30")
  })

  (case "treasury: an empty string is a missing value, not a zero" {
    # the API uses "" for a period it has no figure for; reading that as 0 would drag
    # every average computed over it
    let r = (macro-parse treasury $treasury_payload "avg_interest_rates" "avg_interest_rate_amt" "percent" $tkey "u")
    (eq "treasury: an empty string is a missing value, not a zero" ($r | last | get value) null)
  })

  (case "treasury: an unknown dataset raises and names the ones that exist" {
    let r = (try { macro treasury no_such_dataset; "no error" } catch {|e| $e.msg })
    (has "treasury: an unknown dataset raises and names the ones that exist" $r "avg_interest_rates")
  })

  # ── the record contract, shared by every producer ──
  (case "record: every producer emits the same fields" {
    let a = (macro-parse fred $fred_payload "GDPC1" "u" | first)
    let b = (macro-parse worldbank $wb_payload "NY.GDP.MKTP.CD" "u" | first)
    let c = (macro-parse eurostat $es_payload "prc_hicp_manr" "u" | first)
    let want = ["definition" "reference_period" "retrieved_at" "series" "source" "source_url" "units" "value" "vintage"]
    (eq "record: every producer emits the same fields" [($a | columns | sort) ($b | columns | sort) ($c | columns | sort)] [$want $want $want])
  })

  (case "record: the source url is carried, so a number can be traced back" {
    let r = (macro-parse fred $fred_payload "GDPC1" "https://example.test/xyz" | first)
    (eq "record: the source url is carried, so a number can be traced back" $r.source_url "https://example.test/xyz")
  })

  (case "record: retrieved_at is a real timestamp" {
    let r = (macro-parse fred $fred_payload "GDPC1" "u" | first)
    (is-true "record: retrieved_at is a real timestamp" (($r.retrieved_at | describe) == "string" and ($r.retrieved_at | str length) >= 19))
  })

  # ── the commands ──
  (case "sources: lists every adapter with what it needs" {
    let s = (macro sources)
    (eq "sources: lists every adapter with what it needs" ($s | get source | sort) ["ecb" "eurostat" "fred" "nyfed" "treasury" "worldbank"])
  })

  (case "sources: exactly one source needs a credential, and it is listed last" {
    # the ordering is the recommendation: reach for the public ones first
    let s = (macro sources)
    (eq "sources: exactly one source needs a credential, and it is listed last" [($s | where {|r| ($r.needs | is-not-empty) } | get source) ($s | last | get source)] [["fred"] "fred"])
  })

  (case "sources: exactly one source serves vintages, and it is the same one" {
    # these two facts are the point: the only point-in-time store here is also the only
    # one behind a key, so "what was known then" is the capability a public-only setup lacks
    let s = (macro sources)
    (eq "sources: exactly one source serves vintages, and it is the same one" ($s | where vintage | get source) ["fred"])
  })

  (case "fred: a missing key raises with instructions, not a bare http error" {
    # with-env rather than hide-env: the empty key makes this deterministic whether or not
    # the machine has one, and the command raises before it can reach the network
    let r = (try { with-env {FRED_API_KEY: ""} { macro fred GDPC1 }; "no error" } catch {|e| $e.msg })
    (has "fred: a missing key raises with instructions, not a bare http error" $r "FRED_API_KEY")
  })

  # ── transcription: the path for sources with no API ──
  (case "schema: the four fields a record cannot be built without are required" {
    let s = (macro schema)
    (eq "schema: the four fields a record cannot be built without are required" ($s.required | sort) ["reference_period" "series" "units" "value"])
  })

  (case "schema: additional properties are refused, so a stray key is visible" {
    (eq "schema: additional properties are refused, so a stray key is visible" (macro schema).additionalProperties false)
  })

  (case "transcribe: produces a record indistinguishable in shape from a fetched one" {
    let r = (macro transcribe "https://stats.example/gdp" "2024年二季度GDP同比增长5.3%" {series: "CN-GDP-YOY", value: 5.3, reference_period: "2024-Q2", units: "% y/y"})
    (eq "transcribe: produces a record indistinguishable in shape from a fetched one" [$r.series $r.value $r.source $r.reference_period] ["CN-GDP-YOY" 5.3 "transcribed" "2024-Q2"])
  })

  (case "transcribe: the excerpt is stored beside the value" {
    # this is what separates transcription from invention
    let r = (macro transcribe "https://stats.example/gdp" "二季度GDP同比增长5.3%" {series: "S", value: 5.3, reference_period: "2024-Q2", units: "%"})
    (eq "transcribe: the excerpt is stored beside the value" $r.excerpt "二季度GDP同比增长5.3%")
  })

  (case "transcribe: a missing required field raises and names it" {
    let r = (try { macro transcribe "u" "e" {series: "S", value: 1}; "no error" } catch {|e| $e.msg })
    (has "transcribe: a missing required field raises and names it" $r "reference_period")
  })

  (case "transcribe: blank units are refused" {
    # 18729668435848 is USD, or CNY, or something else entirely — the unit is not optional
    (throws "transcribe: blank units are refused" {
      macro transcribe "u" "e" {series: "S", value: 1, reference_period: "2024", units: "   "}
    })
  })

  (case "transcribe: the url and excerpt are required parameters, not optional ones" {
    # an extracted value with no evidence attached cannot be checked later, so the
    # evidence is structural rather than encouraged
    let t = (expose from-module macro | where name == "macro_transcribe" | first)
    (eq "transcribe: the url and excerpt are required parameters, not optional ones" ($t.input_schema.required | sort) ["excerpt" "observation" "url"])
  })

  # ── the bridge: periods and frames ──
  (case "period: each frequency is recognised and named" {
    let f = (["2024" "2024-Q2" "2025-12" "2026-10-08"] | each {|p| macro-parse period $p | get frequency })
    (eq "period: each frequency is recognised and named" $f ["annual" "quarterly" "monthly" "daily"])
  })

  (case "period: ordinals are comparable ACROSS frequencies" {
    # the reason there is one unit for every frequency: 2024 < 2024-Q2 < 2025-12 < 2026-10-08.
    # this is what alignment will need, and it is why the ordinal is the period's START.
    let o = (["2024" "2024-Q2" "2025-12" "2026-10-08"] | each {|p| macro-parse period $p | get ordinal })
    (is-true "period: ordinals are comparable ACROSS frequencies" (($o == ($o | sort)) and (($o | uniq | length) == 4)))
  })

  (case "period: a quarter is built from its month, not handed to the date parser" {
    # measured: `into datetime` reads "2024-Q2" as 2024-02-12, i.e. FEBRUARY — which would
    # sort Q2 before Q1 and be undetectable downstream. Q2 has to land in April.
    let q2 = (macro-parse period "2024-Q2" | get ordinal)
    (is-true "period: a quarter is built from its month, not handed to the date parser" (
      ($q2 == (macro-parse period "2024-04-01" | get ordinal))
      and ($q2 != (macro-parse period "2024-02-12" | get ordinal))
    ))
  })

  (case "period: an ISO timestamp is reduced to its date" {
    let a = (macro-parse period "2026-10-12T00:00:00" | get ordinal)
    let b = (macro-parse period "2026-10-12" | get ordinal)
    (eq "period: an ISO timestamp is reduced to its date" $a $b)
  })

  (case "slicing: nushell's str substring includes BOTH ends" {
    # asserted because every date built by slicing in this repo depends on this convention,
    # and the quarterly branch got a RIGHT answer from a WRONG slice — `0..4` on "2024-Q2" is
    # "2024-", and the doubled dash that built was tolerated by the date parser. a test that
    # passes for the wrong reason is worse than no test.
    (eq "slicing: nushell's str substring includes BOTH ends" ("261016" | str substring 0..1) "26")
  })

  (case "period: an unreadable period raises rather than being guessed" {
    # a guess would order it somewhere and be invisible; refusing is the only safe answer
    (throws "period: an unreadable period raises rather than being guessed" { macro-parse period "FY2024" })
  })

  # ── frame ──
  (case "frame: records are ordered by period, not by the source's own order" {
    let r = (macro frame $unsorted_records)
    (eq "frame: records are ordered by period, not by the source's own order" $r.periods ["2024-01-01" "2024-02-01" "2024-03-01"])
  })

  (case "frame: values are floats, nulls included" {
    let r = (macro frame $unsorted_records)
    (eq "frame: values are floats, nulls included" $r.values [1.0 null 3.0])
  })

  (case "frame: a missing period is kept as null, because that is information" {
    # "the source reports nothing for February" is a fact about February. dropping it
    # silently would let a gap read as continuity.
    let r = (macro frame $unsorted_records)
    (eq "frame: a missing period is kept as null, because that is information" [($r.observations) ($r.values | length)] [3 3])
  })

  (case "frame: --drop-missing removes the period entirely" {
    let r = (macro frame $unsorted_records --drop-missing)
    (eq "frame: --drop-missing removes the period entirely" [$r.periods $r.values] [["2024-01-01" "2024-03-01"] [1.0 3.0]])
  })

  (case "frame: agreement on series and units is reported, disagreement is not" {
    let one = (macro frame $unsorted_records)
    let many = (macro frame ($unsorted_records | insert 1 {series: "OTHER", source: "fred", value: 2.0, reference_period: "2024-02-01", units: "pct"}))
    (eq "frame: agreement on series and units is reported, disagreement is not" [[$one.series $one.units] [$many.series $many.units]] [["X" "pct"] [null "pct"]])
  })

  (case "frame: a frame spanning two frequencies is refused, not silently juxtaposed" {
    # daily and annual points on one axis with nothing to say they differ is a wrong
    # answer that looks like a right one
    (throws "frame: a frame spanning two frequencies is refused, not silently juxtaposed" {
      macro frame [{reference_period: "2024", value: 1.0} {reference_period: "2024-01", value: 2.0}]
    })
  })

  (case "frame: a record without a period raises and says so" {
    (throws "frame: a record without a period raises and says so" { macro frame [{value: 1.0}] })
  })

  (case "frame: the records can be passed as a parameter, not only piped" {
    # the same lesson as series: a tool a model cannot call is not a capability, and a
    # pipeline is not something a tool call can carry
    let a = (macro frame $unsorted_records)
    let b = ($unsorted_records | macro frame)
    (eq "frame: the records can be passed as a parameter, not only piped" $a.values $b.values)
  })

  (case "frame: the output chains straight into the series kernel" {
    # the point of the whole thing: data layer out, compute kernel in
    let p = (macro frame $unsorted_records --drop-missing | series position)
    (eq "frame: the output chains straight into the series kernel" [$p.latest $p.min $p.max] [3.0 1.0 3.0])
  })

  # ── state: the reading, in one call ──
  (case "state: one call gives the latest value and where it sits" {
    let s = (macro state $unsorted_records)
    (eq "state: one call gives the latest value and where it sits" [$s.latest $s.previous $s.change $s.percentile] [3.0 1.0 2.0 1.0])
  })

  (case "state: a missing period is dropped, not left where it would poison the distribution" {
    # a period the source reports as missing is not an observation. leaving it in makes the
    # series unreadable at best and countable as a zero at worst.
    (eq "state: a missing period is dropped, not left where it would poison the distribution" (macro state $unsorted_records).observations 2)
  })

  (case "state: as_of is the period the latest observation describes" {
    (eq "state: as_of is the period the latest observation describes" (macro state $unsorted_records).as_of "2024-03-01")
  })

  (case "state: series, source and units are carried through from the records" {
    let s = (macro state $unsorted_records)
    (eq "state: series, source and units are carried through from the records" [$s.series $s.source $s.units] ["X" "fred" "pct"])
  })

  (case "state: fewer than two usable observations is refused" {
    (throws "state: fewer than two usable observations is refused" {
      macro state [{series: "X", source: "fred", value: 1.0, reference_period: "2024-01-01", units: "pct"}]
    })
  })

  # ── tool surface ──
  (case "macro: expose yields the commands and nothing else" {
    let names = (expose from-module macro | get name | sort)
    (eq "macro: expose yields the commands and nothing else" $names [
      "macro_ecb" "macro_eurostat" "macro_frame" "macro_fred" "macro_nyfed"
      "macro_schema" "macro_sources" "macro_state" "macro_transcribe" "macro_treasury" "macro_worldbank"
    ])
  })

  (case "macro: every source command can hand back a state" {
    # THE guard for a measured failure. asked to compose fetch | frame | position, a model
    # has to echo every observation back as an argument for the next step — it becomes a
    # courier for numbers it should never touch. --as state answers it in one call, so every
    # command that can reach data must offer it.
    let missing = (
      expose from-module macro
      | where {|t| not ($t.name in ["macro_schema" "macro_sources" "macro_frame" "macro_state" "macro_transcribe"]) }
      | where {|t| not ("as" in ($t.input_schema.properties | columns)) }
      | get name
    )
    (eq "macro: every source command can hand back a state" $missing [])
  })

  (case "frame: the records are a declared parameter, so a model can call it" {
    let t = (expose from-module macro | where name == "macro_frame" | first)
    (is-true "frame: the records are a declared parameter, so a model can call it" ("records" in ($t.input_schema.properties | columns)))
  })

  (case "macro: the parsers do not leak into the tool list" {
    # macro.nu `use`s macro-parse.nu privately for this reason: a user who allowlists
    # `macro` should not find `macro-parse worldbank` in the model's tool list, taking a
    # `payload: record` argument no model can construct
    let names = (expose from-module macro | get name)
    (eq "macro: the parsers do not leak into the tool list" ($names | where {|n| $n | str contains "parse" }) [])
  })

  (case "macro: five of the six sources need no credential at all" {
    # these are the ones a new user can actually try, named here so that a change making
    # one of them key-gated fails loudly rather than at the user's first attempt
    let keyless = (macro sources | where {|s| ($s.needs | is-empty) } | get source | sort)
    (eq "macro: five of the six sources need no credential at all" $keyless ["ecb" "eurostat" "nyfed" "treasury" "worldbank"])
  })
]

emit $results
