# macro-parse.nu — the pure half of the data layer: payload in, point-in-time records out
#
# split out from macro.nu on purpose, for two reasons:
#
#   · it is the half that can be tested without a network. macro.nu's commands are thin
#     wrappers around `http get` plus one of these, so the parsers are where the real
#     logic lives — and they are exercised against canned payloads, the way
#     test/stream.nu exercises the SSE machine against canned bytes.
#
#   · it stays out of the tool surface. macro.nu `use`s it privately, so `expose
#     from-module macro` yields the six commands and not these — a user who allowlists
#     `macro` should not find `macro-parse worldbank` in the model's tool list.

def stamp []: nothing -> string {
  date now | format date "%Y-%m-%dT%H:%M:%S%z"
}

# the start of a period as days since the epoch. one unit for every frequency, so ordinals
# from different frequencies can be compared — which is what alignment will need.
def days-since-epoch [d: string]: nothing -> int {
  let secs = (($d | into datetime | format date "%s") | into int)
  # `/` yields a float in nu, so truncate back — the value is positive, so truncation is floor
  (($secs / 86400) | into int)
}

# a reference period, read into something orderable plus the frequency it implies.
#
# the ordinal is the START of the period (2024-Q2 → 2024-04-01), so it sorts and compares
# across frequencies; the key is the source's own spelling, kept because it is what a human
# and a citation will want.
#
# an unreadable period raises rather than being passed through. a period this cannot read
# would end up ordered lexicographically or not at all, and a mis-ordered series produces
# confidently wrong results that nothing downstream can detect.
export def period [p: string]: nothing -> record {
  # a time component carries no information at this resolution; drop it first so the
  # patterns below only ever see a date
  let s = ($p | str trim | str replace -r 'T[0-9:].*$' '')

  # one if/else chain rather than early returns: nushell's type checker rejects a bare
  # `error make` in tail position against a declared return type, and a branch keeps both
  let parsed = (
    if ($s =~ '^\d{4}$') {
      {key: $s, frequency: "annual", ordinal: (days-since-epoch $"($s)-01-01")}
    } else if ($s =~ '^\d{4}-Q[1-4]$') {
      # measured: `into datetime` reads "2024-Q2" as 2024-02-12 — a silent mis-ordering,
      # and the worst kind, because nothing downstream can tell. build the month instead.
      # nushell's `str substring a..b` includes BOTH ends and clamps out-of-range indices,
      # so `0..4` on "2024-Q2" is "2024-", not "2024". the wrong slice still produced a
      # right answer here because the date parser tolerates the doubled dash it built —
      # this test was passing for the wrong reason until the bounds were measured.
      let y = ($s | str substring 0..3)
      let q = ($s | str substring 6..6 | into int)
      let m = ((($q - 1) * 3) + 1)
      let mm = (if $m < 10 { $"0($m)" } else { $m | into string })
      {key: $s, frequency: "quarterly", ordinal: (days-since-epoch $"($y)-($mm)-01")}
    } else if ($s =~ '^\d{4}-\d{2}$') {
      {key: $s, frequency: "monthly", ordinal: (days-since-epoch $"($s)-01")}
    } else if ($s =~ '^\d{4}-\d{2}-\d{2}$') {
      {key: $s, frequency: "daily", ordinal: (days-since-epoch $s)}
    } else {
      error make { msg: $"cannot read the period '($p)'. expected 2024, 2024-Q2, 2025-12 or 2026-10-08 — an unreadable period must not be guessed at, because a guess mis-orders the series silently" }
    }
  )

  $parsed
}

# one point-in-time record. every producer builds the same shape, so a value pulled from
# an API and a value transcribed from a PDF are the same kind of thing downstream.
export def pit [
  series: string
  value: any
  reference_period: string
  vintage: any
  units: any
  source: string
  url: string
  note: string
]: nothing -> record {
  {
    series: $series
    source: $source
    value: $value
    reference_period: $reference_period
    vintage: $vintage
    units: $units
    retrieved_at: (stamp)
    source_url: $url
    definition: {
      kind: "macro-observation"
      reference_period: $"the period the value describes \(($note)\) — not when it was published"
      vintage: (if $vintage == null { "unknown for this source: it serves only the latest revision" } else { "the date this revision became available" })
      value: "null means the source reports the period as missing, not that it is zero"
    }
  }
}

# FRED / ALFRED. numbers arrive as strings, and "." marks a missing period.
# realtime_start is the date this revision became available — which is exactly the
# vintage, so a query with no --as-of yields first-publication dates.
export def fred [payload: record, series: string, url: string]: nothing -> list<record> {
  $payload.observations | each {|o|
    let v = (if ($o.value == ".") { null } else { $o.value | into float })
    pit $series $v $o.date $o.realtime_start ($payload.units? | default null) "fred" $url "the series' own frequency"
  }
}

# World Bank. form: [ {page…}, [ {indicator, country, date, value, unit, …}, … ] ].
# annual, and the value is null for a year the source does not report.
export def worldbank [payload: list, indicator: string, url: string]: nothing -> list<record> {
  if ($payload | length) < 2 {
    error make { msg: $"worldbank returned no data: ($payload | to json -r | str substring 0..200)" }
  }
  $payload | get 1 | each {|r|
    let unit = (if ($r.unit | is-empty) { null } else { $r.unit })
    pit $indicator $r.value $r.date null $unit "worldbank" $url "annual"
  }
}

# Eurostat, SDMX/JSON-stat. the mapping is positional on both sides —
# `dimension.time.category.index` maps period → position and `value` maps position →
# number — so one is unreadable without the other.
export def eurostat [payload: record, dataset: string, url: string]: nothing -> list<record> {
  let idx = ($payload.dimension.time.category.index | transpose period pos)
  let updated = ($payload.updated? | default null)

  # the unit is a *dimension*, not a field — `dimension.unit.category.label` maps unit
  # code → name, as in {RCH_A: "Annual rate of change"}. a response spanning several
  # units cannot be labeled by picking one, so it is left null rather than guessed: with
  # positions flattened across dimensions, choosing the first would silently mislabel the
  # observations that belong to the others.
  let unit_labels = ($payload.dimension.unit?.category.label? | default null)
  let unit = (
    if $unit_labels == null { null }
    else if (($unit_labels | columns | length) == 1) { $unit_labels | values | first }
    else { null }
  )

  $idx | each {|e|
    let v = ($payload.value | get --optional ($e.pos | into string))
    pit $dataset $v $e.period $updated $unit "eurostat" $url "the dataset's reported period"
  }
}

# the series' own description, from FRED's metadata endpoint
export def fred-meta [payload: record]: nothing -> record {
  let s = ($payload.seriess | first)
  {
    title: $s.title
    units: $s.units
    frequency: $s.frequency
    seasonal: $s.seasonal_adjustment
    last_updated: $s.last_updated
  }
}

# ECB, SDMX-JSON 2.0.
#
# measured: this endpoint answers with a content type nu does not treat as JSON, so `http
# get` hands back a STRING. the caller must `from json` it first — without that, everything
# below dies with "string doesn't support cell paths", which reads like a malformed payload
# rather than a parsing step that was skipped.
export def ecb [payload: record, series: string, url: string]: nothing -> list<record> {
  let times = ($payload.structure.dimensions.observation | first | get values | get id)
  let key = ($payload.dataSets | first | get series | columns | first)
  let obs = ($payload.dataSets | first | get series | get $key | get observations)
  let labels = (ecb-labels $payload $key)
  let unit = (ecb-unit $labels)
  $times | enumerate | each {|e|
    let row = ($obs | get --optional ($e.index | into string))
    # an observation is [value, ...attributes] — the value is the first element, and the
    # trailing nulls are attributes this parser does not use. reading the array whole would
    # turn every value into a list.
    let v = (if $row == null { null } else { $row | first })
    let rec = (pit $series $v $e.item null $unit "ecb" $url "the series' own frequency")
    # most ECB dataflows carry no unit field at all, so the decoded dimension labels are
    # the only description of what the number is — "Deposit facility", "Key interest rate",
    # "Daily". without them a null unit leaves the record unreadable.
    $rec | insert series_labels $labels
  }
}

# the ECB series key is colon-separated POSITIONS into structure.dimensions.series, so it
# decodes to one label per dimension. this is the only self-description the payload holds,
# and for many dataflows the only place a unit appears at all.
def ecb-labels [payload: record, key: string]: nothing -> record {
  let dims = ($payload.structure.dimensions.series)
  let parts = ($key | split row ":")
  let pairs = ($parts | enumerate | each {|e|
    let d = ($dims | get --optional $e.index)
    if $d == null { null } else {
      let v = ($d.values | get --optional ($e.item | into int))
      if $v == null { null } else { {id: $d.id, value: ($v | get --optional name | default ($v | get id))} }
    }
  } | compact)
  $pairs | reduce --fold {} {|p, acc| $acc | upsert $p.id $p.value }
}

def ecb-unit [labels: record]: nothing -> any {
  let u = ($labels | transpose id value | where {|l| ($l.id | str uppercase) in ["UNIT" "UNIT_MEASURE"] })
  if ($u | is-empty) { null } else { $u | first | get value }
}

# the New York Fed's markets API — where the US policy rate is published as structured
# data with no key. percentRate is the effective funds rate that printed; the target range
# is the instrument the FOMC actually sets, so both are carried.
export def nyfed [payload: record, url: string]: nothing -> list<record> {
  $payload.refRates | each {|r|
    let rec = (pit $r.type $r.percentRate $r.effectiveDate null "percent" "nyfed" $url "daily")
    let from = ($r | get --optional targetRateFrom)
    let to = ($r | get --optional targetRateTo)
    $rec | insert target_range (if $from == null { null } else { $"($from)–($to)" })
  }
}

# US Treasury fiscal data. every number arrives as a STRING, the period field is always
# record_date, and — the part that bites — a Treasury endpoint is NOT a series.
#
# measured: `avg_interest_rates` returns four rows for one record_date, told apart by
# security_desc (Bills, Notes, Bonds, TIPS). without the discriminator in the series id
# those read as four contradictory values for a single period rather than four series, so
# the columns that distinguish them are named by the dataset table in macro.nu.
export def treasury [
  payload: record
  dataset: string
  value_field: string
  units: any
  key_fields: list<string>
  url: string
]: nothing -> list<record> {
  $payload.data | each {|r|
    let raw = ($r | get --optional $value_field)
    let v = (if $raw == null or (($raw | into string) | str trim | is-empty) { null } else { $raw | into float })
    let suffix = ($key_fields | each {|k| $r | get --optional $k } | compact | str join "/")
    let sid = (if ($suffix | is-empty) { $dataset } else { $"($dataset):($suffix)" })
    pit $sid $v $r.record_date null $units "treasury" $url "as recorded"
  }
}
