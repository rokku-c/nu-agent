# macro.nu — the data layer: pull a series from a source and record it point-in-time
#
#   use macro.nu
#
#   macro sources                                            # what is available, and what it needs
#   macro worldbank CN NY.GDP.MKTP.CD --limit 3              # keyless
#   macro eurostat prc_hicp_manr --params {geo: EA, coicop: CP00}
#   macro fred GDPC1 --as-of 2024-01-01                      # needs FRED_API_KEY; vintage-aware
#
#   # a source with no API at all: the model transcribes, this validates and records it
#   macro schema                                             # hand this to the model as its output format
#   macro transcribe <url> <excerpt> <observation>
#
# ── the record, and why it has this shape ──
# a datum is never just a value. it is {value, reference_period, vintage, units, source},
# because "GDP is 18.7 trillion" is not a fact until you know which quarter it describes,
# when it became known, and in what units. a source that cannot answer a field says so with
# null and a note in `definition`, rather than quietly leaving the field out.
#
# ── the rule this module holds ──
# the model never produces a number. it may TRANSCRIBE one it can see in a document — that
# is extraction, not generation, and it is checkable because the excerpt is stored beside
# the value. `macro transcribe` refuses an observation with no evidence, for exactly that
# reason: a number whose source text is missing is unverifiable, and unverifiable is the
# same as invented.
#
# ── a deliberate omission ──
# there is no `http` tool here. each source is its own narrow command, so the model gets
# "read Eurostat", not "reach any URL on the internet" — the same reason this repo exposes
# `read` rather than `bash`.
#
# the parsing half lives in macro-parse.nu, which this file `use`s privately: the parsers
# are pure, testable against canned payloads, and stay out of the exposed tool list.

use ./macro-parse.nu
use ./series.nu
use ./cache.nu

const FRED_URL = "https://api.stlouisfed.org/fred"
const WORLDBANK_URL = "https://api.worldbank.org/v2"
const EUROSTAT_URL = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0"
const ECB_URL = "https://data-api.ecb.europa.eu/service/data"
const NYFED_URL = "https://markets.newyorkfed.org/api"
const TREASURY_URL = "https://api.fiscaldata.treasury.gov/services/api/fiscal_service"

# the Treasury endpoints this knows. the API is uniform in shape and not in content, so the
# mapping is data rather than code — adding a dataset is one row here.
#
# `key` names the columns that tell one series from another inside a single endpoint. it is
# not decoration: `avg_interest_rates` returns four rows per record_date, and without these
# in the series id they read as four contradictory values for one period.
const TREASURY_DATASETS = [
  {
    name: "avg_interest_rates"
    path: "v2/accounting/od/avg_interest_rates"
    value: "avg_interest_rate_amt"
    units: "percent"
    key: ["security_type_desc" "security_desc"]
  }
]

# the sources, and what each one can honestly answer.
#
# public first: every source above the line is reachable with no credential at all, which
# is the set to build on. `vintage: true` means past revisions are served — i.e. you can
# ask what was known on a given date, which is the only honest way to evaluate a forecast
# after the fact. exactly one source below does that, and it is the one that needs a key.
export def sources []: nothing -> table {
  [
    {source: "ecb"       needs: ""             vintage: false note: "ECB Data Portal (SDMX): euro-area policy rates, yields, FX, monetary aggregates"}
    {source: "eurostat"  needs: ""             vintage: false note: "EU / euro-area statistics; the dataset's own update time stands in for a vintage"}
    {source: "nyfed"     needs: ""             vintage: false note: "US effective federal funds rate, with the FOMC target range"}
    {source: "treasury"  needs: ""             vintage: false note: "US Treasury fiscal data — see `macro treasury` for the datasets known here"}
    {source: "worldbank" needs: ""             vintage: false note: "long-run annual indicators by country; no revision history"}
    {source: "fred"      needs: "FRED_API_KEY" vintage: true  note: "800k+ series, and the only point-in-time store here: --as-of reads a real ALFRED vintage"}
  ]
}

# ── fetching ──
# the only place a URL is built. each returns {payload, url} so the record can carry the
# exact request that produced it.

def fred-key []: nothing -> string {
  let key = ($env.FRED_API_KEY? | default "")
  if ($key | is-empty) {
    error make { msg: "FRED_API_KEY is not set. it is free (https://fredaccount.stlouisfed.org/apikeys), or use eurostat / worldbank, which need no key — see `macro sources`" }
  }
  $key
}

def get-fred [series: string, as_of: any, limit: any]: nothing -> record {
  let key = (fred-key)
  # realtime_start/end pin the vintage. without them FRED answers with the latest revision,
  # and each row's own realtime_start is then its first publication date.
  let window = (if $as_of == null { "" } else { $"&realtime_start=($as_of)&realtime_end=($as_of)" })
  let cap = (if $limit == null { "" } else { $"&limit=($limit)" })
  let url = $"($FRED_URL)/series/observations?series_id=($series)&file_type=json&api_key=($key)&sort_order=desc($window)($cap)"
  let meta_url = $"($FRED_URL)/series?series_id=($series)&file_type=json&api_key=($key)"
  let body = ((cache fetch $url --source fred).payload)
  # units come from the metadata endpoint; a missing one must not sink the observations
  let units = (try { macro-parse fred-meta ((cache fetch $meta_url --source fred).payload) | get units } catch { null })
  {payload: ($body | insert units $units), url: $url}
}

def get-worldbank [country: string, indicator: string, limit: any]: nothing -> record {
  let cap = (if $limit == null { 100 } else { $limit })
  let url = $"($WORLDBANK_URL)/country/($country)/indicator/($indicator)?format=json&per_page=($cap)"
  {payload: ((cache fetch $url --source worldbank).payload), url: $url}
}

def get-eurostat [dataset: string, params: any, limit: any]: nothing -> record {
  let q = (
    if $params == null { "" } else {
      ($params | transpose k v | each {|e| $"($e.k)=($e.v)" } | str join "&")
    }
  )
  let head = (if ($q | is-empty) { $"($EUROSTAT_URL)/data/($dataset)?" } else { $"($EUROSTAT_URL)/data/($dataset)?($q)" })
  let cap = (if $limit == null { "" } else { $"&lastTimePeriod=($limit)" })
  {payload: ((cache fetch $"($head)($cap)" --source eurostat).payload), url: $"($head)($cap)"}
}

def get-ecb [flow: string, key: string, limit: any]: nothing -> record {
  let cap = (if $limit == null { "" } else { $"&lastNObservations=($limit)" })
  let url = $"($ECB_URL)/($flow)/($key)?format=jsondata($cap)"
  # `from json` is load-bearing: this endpoint's content type is not one nu treats as JSON,
  # so `http get` alone yields a string. the cache stores that string as it arrived, and the
  # parse happens here — so a change to the parser never costs a refetch.
  {payload: ((cache fetch $url --source ecb).payload | from json), url: $url}
}

def get-nyfed [limit: any]: nothing -> record {
  let cap = (if $limit == null { 1 } else { $limit })
  let url = $"($NYFED_URL)/rates/unsecured/effr/last/($cap).json"
  {payload: ((cache fetch $url --source nyfed).payload), url: $url}
}

def get-treasury [d: record, limit: any]: nothing -> record {
  let cap = (if $limit == null { 100 } else { $limit })
  let url = $"($TREASURY_URL)/($d.path)?sort=-record_date&page%5Bsize%5D=($cap)"
  {payload: ((cache fetch $url --source treasury).payload), url: $url}
}

# ── commands ──

# FRED — a US-centric but enormous library, and the only source here with real vintages
export def fred [
  series: string        # a FRED series id, e.g. GDPC1
  --as-of: string       # return what was known on this date (an ALFRED vintage), e.g. 2024-01-01
  --limit: int          # most recent N observations
  --info                # return the series metadata instead of the observations
  --as: string = "records"   # records | frame | state
]: nothing -> any {
  if $info {
    let key = (fred-key)
    let u = $"($FRED_URL)/series?series_id=($series)&file_type=json&api_key=($key)"
    return (macro-parse fred-meta ((cache fetch $u --source fred).payload))
  }
  let r = (get-fred $series $as_of $limit)
  view (macro-parse fred $r.payload $series $r.url) $as
}

# World Bank — keyless, annual, long history, one country at a time
export def worldbank [
  country: string       # ISO country code, e.g. CN
  indicator: string     # indicator id, e.g. NY.GDP.MKTP.CD
  --limit: int          # how many years back
  --as: string = "records"   # records | frame | state
]: nothing -> any {
  let r = (get-worldbank $country $indicator $limit)
  view (macro-parse worldbank $r.payload $indicator $r.url) $as
}

# Eurostat — keyless; the euro-area series the ECB actually targets
export def eurostat [
  dataset: string       # dataset code, e.g. prc_hicp_manr
  --params: record      # dimension filters, e.g. {geo: EA, coicop: CP00}
  --limit: int          # most recent N periods
  --as: string = "records"   # records | frame | state
]: nothing -> any {
  let r = (get-eurostat $dataset $params $limit)
  view (macro-parse eurostat $r.payload $dataset $r.url) $as
}

# the ECB Data Portal — keyless. this is where the euro-area policy rate lives, along with
# yields, FX and the monetary aggregates. the key is the ECB's own dotted series key.
export def ecb [
  flow: string          # data flow, e.g. FM (financial markets) or BSI (bank interest rates)
  key: string           # series key, e.g. D.U2.EUR.4F.KR.DFR.LEV — the deposit facility rate
  --limit: int          # most recent N observations
  --as: string = "records"   # records | frame | state
]: nothing -> any {
  let r = (get-ecb $flow $key $limit)
  view (macro-parse ecb $r.payload $key $r.url) $as
}

# the New York Fed — keyless. the US effective federal funds rate and the FOMC's target
# range: the closest thing to the policy instrument itself, published daily.
export def nyfed [
  --limit: int          # how many recent days
  --as: string = "records"   # records | frame | state
]: nothing -> any {
  let r = (get-nyfed $limit)
  view (macro-parse nyfed $r.payload $r.url) $as
}

# US Treasury fiscal data — keyless. the API is uniform in shape and not in content, so the
# dataset has to be named: run `macro sources` for the note, or see TREASURY_DATASETS.
export def treasury [
  dataset: string       # e.g. avg_interest_rates
  --limit: int
  --as: string = "records"   # records | frame | state
]: nothing -> any {
  let d = ($TREASURY_DATASETS | where name == $dataset | first)
  if $d == null {
    error make { msg: $"unknown treasury dataset '($dataset)'. known: ($TREASURY_DATASETS | get name | str join ', ')" }
  }
  let r = (get-treasury $d $limit)
  view (macro-parse treasury $r.payload $dataset $d.value $d.units $d.key $r.url) $as
}

# ── the three views of a fetched series ──
# `records` is the default, because provenance first. the other two exist because of a
# measured failure: asked to compose `fetch | frame | position`, a model has to echo every
# observation back as a JSON argument for the next step — it becomes a courier for numbers
# it must not be handling, once per step. handing the whole reading back from the one call
# that can reach the data is the fix.

# render fetched records in the shape the caller asked for
def view [records: list<record>, as: string]: nothing -> any {
  if $as == "records" {
    $records
  } else if $as == "frame" {
    frame $records
  } else if $as == "state" {
    state $records
  } else {
    error make { msg: $"unknown --as '($as)': use records (provenance, one per period), frame (an ordered numeric series), or state (the latest reading and where it sits)" }
  }
}

# the value of a field when every record agrees on it, and null when they do not. a frame
# whose records disagree about their units or their series is not one series, and saying so
# with null is better than picking the first and being wrong for the rest.
def agree [xs: list]: nothing -> any {
  let u = ($xs | compact | uniq)
  if ($u | length) == 1 { $u | first } else { null }
}

# the current-state reading of a series — the latest value together with where it sits in
# its own history. this is what "what is happening now" means for one series: the number
# alone says nothing, and the number with its position says most of what there is to say.
#
# missing periods are dropped here unconditionally, and not as a convenience: a period the
# source reports as missing is not an observation, so it cannot be placed in a distribution
# of observations. the frame keeps it (that it is missing is itself information); a reading
# has no use for it.
export def state [
  records?: list<record>   # records from a source command; omit to pipe them in
]: any -> record {
  let raw = (if $records != null { $records } else { $in })
  let f = (frame $raw --drop-missing)
  let n = ($f.values | length)
  if $n < 2 {
    error make { msg: $"need at least 2 observations to place the latest one — this series has ($n) after dropping the periods the source reports as missing" }
  }

  let p = (series position $f.values)
  {
    series: $f.series
    source: $f.source
    units: $f.units
    frequency: $f.frequency
    as_of: ($f.periods | last)
    observations: $p.observations
    latest: $p.latest
    previous: $p.previous
    change: $p.change
    percentile: $p.percentile
    zscore: $p.zscore
    min: $p.min
    max: $p.max
    range_position: $p.range_position
    definition: {
      kind: "state"
      latest: "the most recent observation, in the series' own units"
      percentile: $p.definition.percentile
      zscore: $p.definition.zscore
      as_of: "the period the latest observation describes — not when it was published"
      observations: $n
    }
  }
}

# turn point-in-time records into an ordered numeric series — the bridge from the data layer
# to the compute kernel.
#
# this is the step that was missing: `macro nyfed` returns records carrying string periods
# and provenance, while `series stats` and friends want a list of numbers. a frame is both —
# the values in time order, with the periods kept alongside and the provenance summarised.
#
# the output has a `values` field, which is exactly what the series commands accept, so
# `macro nyfed --limit 100 | macro frame | series stats` works end to end.
export def frame [
  records?: list<record>   # records from a source command; omit to pipe them in
  --drop-missing           # drop periods the source reports as missing, instead of carrying a null
]: any -> record {
  let raw = (if $records != null { $records } else { $in })
  if $raw == null {
    error make { msg: "no records. pass them as the first argument, or pipe them in — e.g. `macro nyfed --limit 100 | macro frame`" }
  }
  if ($raw | is-empty) {
    error make { msg: "no records to frame — the source returned nothing" }
  }

  # a record without a period cannot be placed, and one without a value field cannot be
  # read. note `value` is allowed to BE null: that is a period the source reports as
  # missing, which is information, not an absence of information.
  let bad = ($raw | enumerate | where {|e|
    let cols = ($e.item | columns)
    not (("reference_period" in $cols) and ("value" in $cols))
  } | first)
  if $bad != null {
    error make { msg: $"record ($bad.index) is not a point-in-time record — it has: (($bad.item | columns) | str join ', '). expected the fields `macro series` produces" }
  }

  let placed = ($raw | each {|r|
    let p = (macro-parse period $r.reference_period)
    let v = (if $r.value == null { null } else { $r.value | into float })
    {ordinal: $p.ordinal, key: $p.key, frequency: $p.frequency, value: $v, record: $r}
  } | sort-by ordinal)

  # mixing frequencies in one frame would put daily and annual points on the same axis with
  # nothing to say they are different. refuse instead, and let the caller align deliberately.
  let freqs = ($placed | get frequency | uniq)
  if ($freqs | length) > 1 {
    error make { msg: $"these records mix frequencies: ($freqs | str join ', '). a frame is one series at one frequency — frame each source separately, then align them" }
  }

  let kept = (if $drop_missing { $placed | where {|r| $r.value != null } } else { $placed })

  {
    series: (agree ($kept | each {|r| $r.record | get --optional series }))
    source: (agree ($kept | each {|r| $r.record | get --optional source }))
    units: (agree ($kept | each {|r| $r.record | get --optional units }))
    frequency: ($freqs | first)
    periods: ($kept | get key)
    values: ($kept | get value)
    observations: ($kept | length)
    definition: {
      kind: "frame"
      ordering: "ascending by the start of each period; the source's own ordering is not trusted"
      series: "the source's series id when every record agrees on one, else null — a frame spanning several series is not one series"
      missing: (if $drop_missing { "periods the source reports as missing are dropped" } else { "a period the source reports as missing is kept as a null value, which is information and not an absence of it. the series commands cannot read a null, so pass --drop-missing (or use --as state, which drops them) before handing these values on" })
      values: "ready for the `series` commands once any missing periods are dropped — they accept a record with a `values` field"
    }
  }
}

# the shape a transcribed observation must have. hand it to the model as its structured
# output format (Anthropic output_format / OpenAI response_format), so the constraint is
# enforced by the API rather than requested politely in a prompt.
export def schema []: nothing -> record {
  {
    '$schema': "https://json-schema.org/draft/2020-12/schema"
    title: "a macro observation transcribed from a document"
    type: "object"
    properties: {
      series: {type: "string", description: "an identifier for the series, stable across transcriptions"}
      value: {type: ["number", "null"], description: "the number exactly as printed; null if the document reports the period as missing"}
      reference_period: {type: "string", description: "the period the number DESCRIBES, e.g. 2024-Q2 or 2024-06 — not the publication date"}
      units: {type: "string", description: "as printed, e.g. '% y/y' or 'billion CNY'. must not be blank: a unitless number is not recordable"}
      vintage: {type: ["string", "null"], description: "the publication date, if the document states one"}
    }
    required: ["series" "value" "reference_period" "units"]
    additionalProperties: false
  }
}

# record an observation the model transcribed from a source that has no API.
#
# url and excerpt are REQUIRED positional parameters, and that is the design: an extracted
# value with no evidence beside it cannot be checked, and an unchecked number from a model
# is indistinguishable from a made-up one. a transcription is only trustworthy because the
# text it came from is right there.
export def transcribe [
  url: string           # where it came from
  excerpt: string       # the text the value was read from, quoted verbatim
  observation: record   # the model's output, conforming to `macro schema`
]: nothing -> record {
  let need = ["series" "value" "reference_period" "units"]
  let missing = ($need | where {|k| ($observation | get --optional $k) == null })
  if ($missing | is-not-empty) {
    error make { msg: $"the observation is missing required field\(s\): ($missing | str join ', '). run `macro schema` for the expected shape" }
  }
  if (($observation.units | into string) | str trim | is-empty) {
    error make { msg: "units is blank. a number without its unit is not recordable — 18729668435848 is USD, or CNY, or something else entirely" }
  }
  let v = ($observation.value | into float)
  let rec = (
    macro-parse pit $observation.series $v $observation.reference_period ($observation.vintage? | default null) $observation.units "transcribed" $url "as stated in the document"
    | insert excerpt $excerpt
  )
  # a transcription is archived like any fetch — same store, same key (its source URL). so
  # "what did this document say, and when did we read it" is answerable later, and a
  # transcribed value sits in the same archive as a fetched one.
  cache put $url $rec --source transcribed | ignore
  $rec
}
