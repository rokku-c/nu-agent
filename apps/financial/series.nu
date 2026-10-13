# series.nu — deterministic return and risk statistics over a numeric series
#
#   use series.nu
#
#   # prices -> returns
#   [100 110 99] | series returns --method log
#
#   # chaining works: a command takes a bare list, a table + --column, or the record
#   # a sibling command just produced
#   [100 110 99] | series returns --method log | series volatility
#
#   [[date close]; [2024-01-01 100.0] [2024-01-02 110.0]] | series returns --column close
#
#   [100 110 99] | series stats
#   [100 120 90 110] | series drawdown
#   [0.01 -0.02 0.03 -0.04] | series var --level 0.95
#
# ── why every output carries a definition ──
# "volatility is 0.18" is not a fact until you know the annualization factor and the
# return convention behind it. finance has several defensible definitions of nearly
# every word, so each command reports the one it used in a `definition` field instead
# of leaving it to a docstring nobody reads. an agent that quotes the number and drops
# the definition produces a plausible, uncheckable claim — which is the failure mode
# this module exists to prevent.
#
# ── numerical note ──
# variance is computed two-pass (deviations from the mean), never as E[x²] − E[x]².
# the one-pass form cancels catastrophically when the mean dominates the spread, which
# is the normal case for price levels and for small returns.

# ── the series contract ──
# every exported command accepts the same three input shapes, so that (a) a bare list
# is convenient at the prompt and (b) the output of one command feeds the next without
# unwrapping.
#
# ── and it must be a PARAMETER, not only the pipe ──
# measured: a command whose only input is the pipeline is exposed to a model with an
# empty property set (toon_encode → `"properties":{}`) and is therefore uncallable —
# a tool call carries its arguments as JSON, and a pipeline is not one of them. so the
# series is a declared optional positional, which expose puts in the schema, while the
# pipeline keeps working for a human at the prompt and for chaining.

# the series, whether it arrived as a positional or over the pipe
def given [values: any, piped: any]: nothing -> any {
  if $values != null { $values } else { $piped }
}

# accept a bare list of numbers, a table plus --column, or a record with `values`
def take-series [input: any, column: any]: nothing -> list<float> {
  let d = ($input | describe)
  let raw = (
    if $column != null {
      if not ($d | str starts-with "table") {
        error make { msg: $"--column was given but the input is ($d), not a table" }
      }
      let cols = ($input | columns)
      if not ($column in $cols) {
        error make { msg: $"no column '($column)' — the input has: ($cols | str join ', ')" }
      }
      $input | get $column
    } else if ($d | str starts-with "record") {
      let v = ($input | get --optional values)
      if $v == null {
        error make { msg: $"expected a `values` field — this record has: (($input | columns) | str join ', '). pass a bare list, or pipe from series returns / cumulate" }
      }
      $v
    } else if ($d | str starts-with "table") {
      error make { msg: $"input is a table — name the series column with --column. columns: (($input | columns) | str join ', ')" }
    } else if ($d | str starts-with "list") {
      $input
    } else {
      error make { msg: $"expected a list of numbers, a table + --column, or a record with `values` — got ($d)" }
    }
  )

  if ($raw | is-empty) {
    error make { msg: "the series is empty" }
  }

  # every element must be numeric; ints are widened to floats here and nowhere else
  let bad = ($raw | enumerate | where {|x| not (($x.item | describe) in ["int" "float"]) } | first)
  if $bad != null {
    error make { msg: $"element ($bad.index) is not a number: ($bad.item | describe)" }
  }
  $raw | each {|v| $v | into float }
}

def check-method [m: string]: nothing -> string {
  if not ($m in ["simple" "log"]) {
    error make { msg: $"unknown method '($m)' — use simple or log" }
  }
  $m
}

def check-from [f: string]: nothing -> string {
  if not ($f in ["returns" "prices"]) {
    error make { msg: $"unknown --from '($f)' — use returns or prices" }
  }
  $f
}

# returns, either as given, or computed from prices first. one code path, so
# `series returns` and `series volatility --from prices` can never disagree.
def resolve-returns [raw: list<float>, from: string, method: string]: nothing -> list<float> {
  let f = (check-from $from)
  if $f == "returns" { return $raw }

  let m = (check-method $method)
  if ($raw | length) < 2 {
    error make { msg: $"need at least 2 prices for a return, got ($raw | length)" }
  }
  if $m == "log" {
    let bad = ($raw | enumerate | where {|x| $x.item <= 0.0 } | first)
    if $bad != null {
      error make { msg: $"log returns need strictly positive prices; element ($bad.index) is ($bad.item)" }
    }
  }
  $raw | window 2 | each {|w|
    let prev = ($w | first)
    let cur = ($w | last)
    if $m == "log" { $cur / $prev | math ln } else { ($cur / $prev) - 1.0 }
  }
}

# the central moments, two-pass. m2/m3/m4 are SUMS of deviations, not averages —
# the callers divide, because sample vs population is their business, not this one's.
def moments [x: list<float>]: nothing -> record {
  let n = ($x | length)
  let mean = ($x | math avg)
  let dev = ($x | each {|v| $v - $mean })
  let sq = ($dev | each {|d| $d * $d })
  {
    n: $n
    mean: $mean
    m2: ($sq | math sum)
    m3: ($dev | each {|d| $d * $d * $d } | math sum)
    m4: ($sq | each {|d| $d * $d } | math sum)
  }
}

# standard deviation; null when n < 2 (undefined, not zero)
def sd-of [x: list<float>, population: bool]: nothing -> any {
  let n = ($x | length)
  if $n < 2 { return null }
  let mt = (moments $x)
  let denom = (if $population { $n } else { $n - 1 })
  ($mt.m2 / ($denom | into float)) | math sqrt
}

# linear-interpolation quantile — the "type 7" definition (R's default, numpy's
# default). nushell 0.116 ships no quantile command, so it is implemented here, and
# the interpolation rule is named in every definition that uses it: a quantile
# without its interpolation rule is not reproducible.
def quantile [x: list<float>, q: float]: nothing -> float {
  if $q < 0.0 or $q > 1.0 {
    error make { msg: $"quantile argument must be in [0, 1], got ($q)" }
  }
  let n = ($x | length)
  if $n == 1 { return ($x | first) }
  let s = ($x | sort)
  let h = (($n - 1) | into float) * $q
  let lo = ($h | math floor | into int)
  let hi = ([($lo + 1) ($n - 1)] | math min)
  let frac = ($h - ($lo | into float))
  ($s | get $lo) + $frac * (($s | get $hi) - ($s | get $lo))
}

def defined [fields: record, definition: record]: nothing -> record {
  $fields | insert definition $definition
}

# ── commands ──

# a return series from a price series — consecutive ratios, one shorter than the input
export def returns [
  values?: list<float>          # the price series; omit it to pipe the series in instead
  --method: string = "simple"   # simple (p_t/p_{t-1} − 1) | log (ln(p_t/p_{t-1}))
  --column: string              # when the input is a table: which column holds the prices
]: any -> record {
  let p = (take-series (given $values $in) $column)
  let m = (check-method $method)
  let vals = (resolve-returns $p "prices" $m)
  (defined {
    values: $vals
  } {
    kind: "return"
    method: $m
    input: "prices"
    prices: ($p | length)
    observations: ($vals | length)
  })
}

# compound a return series into a cumulative growth series
export def cumulate [
  values?: list<float>          # the return series; omit it to pipe instead
  --method: string = "simple"   # must match the method that produced the returns
  --start: float = 1.0          # the value the series starts from
  --column: string
]: any -> record {
  let r = (take-series (given $values $in) $column)
  let m = (check-method $method)
  # reduce, not `each` with a mut accumulator: nushell forbids capturing a mutable
  # variable in a closure, so a running total has to be folded through
  let vals = (
    if $m == "log" {
      $r
      | reduce --fold [0.0] {|x, acc| $acc | append (($acc | last) + $x) }
      | skip 1
      | each {|s| $start * ($s | math exp) }
    } else {
      $r
      | reduce --fold [$start] {|x, acc| $acc | append (($acc | last) * (1.0 + $x)) }
      | skip 1
    }
  )
  (defined {
    values: $vals
  } {
    kind: "cumulative"
    method: $m
    input: "returns"
    start: $start
    observations: ($vals | length)
  })
}

# descriptive statistics of a series
export def stats [
  values?: list<float>          # the series; omit it to pipe instead
  --column: string
  --population                # divide by n instead of n−1
]: any -> record {
  let x = (take-series (given $values $in) $column)
  let mt = (moments $x)
  let n = $mt.n
  let sd = (sd-of $x $population)
  let m2c = ($mt.m2 / ($n | into float))
  let degenerate = ($m2c <= 0.0)

  # bias-corrected Fisher–Pearson skewness and excess kurtosis — the same convention
  # as scipy.stats.skew(bias=False) / kurtosis(bias=False), named in the definition
  # so the number can be checked against a reference implementation
  let skew = (
    if $n < 3 or $degenerate { null } else {
      let g1 = (($mt.m3 / ($n | into float)) / ($m2c ** 1.5))
      $g1 * ((($n * ($n - 1)) | into float) | math sqrt) / (($n - 2) | into float)
    }
  )
  let kurtosis = (
    if $n < 4 or $degenerate { null } else {
      let g2 = (($mt.m4 / ($n | into float)) / ($m2c * $m2c)) - 3.0
      ((($n + 1) | into float) * $g2 + 6.0) * (($n - 1) | into float) / ((($n - 2) * ($n - 3)) | into float)
    }
  )

  (defined {
    n: $n
    mean: $mt.mean
    sd: $sd
    min: ($x | math min)
    max: ($x | math max)
    median: ($x | math median)
    skew: $skew
    kurtosis: $kurtosis
  } {
    kind: "stats"
    sd: (if $population { "population (÷ n)" } else { "sample (÷ n−1)" })
    skew: "bias-corrected Fisher–Pearson (scipy bias=False); null when n<3 or the series is constant"
    kurtosis: "excess, so a normal is 0; bias-corrected (scipy bias=False); null when n<4 or the series is constant"
    observations: $n
  })
}

# annualized volatility of a return series
export def volatility [
  values?: list<float>          # the return series, or prices with --from prices
  --from: string = "returns"    # returns | prices — prices are converted first
  --method: string = "log"      # used only when --from prices
  --annualize: int = 252        # periods per year; 0 reports the per-period figure
  --column: string
  --population
]: any -> record {
  let raw = (take-series (given $values $in) $column)
  let src = (check-from $from)
  let r = (resolve-returns $raw $src $method)
  if ($r | length) < 2 {
    error make { msg: $"need at least 2 returns, got ($r | length)" }
  }
  let sd = (sd-of $r $population)
  let factor = (if $annualize > 0 { ($annualize | into float) | math sqrt } else { 1.0 })

  (defined {
    value: ($sd * $factor)
  } {
    kind: "volatility"
    input: $src
    method: (if $src == "prices" { (check-method $method) } else { null })
    sd: (if $population { "population (÷ n)" } else { "sample (÷ n−1)" })
    annualization: (if $annualize > 0 { $"× sqrt\(($annualize))" } else { "none — per-period" })
    observations: ($r | length)
  })
}

# the drawdown family over a price or cumulative-growth series
export def drawdown [
  values?: list<float>          # the price or cumulative-growth series
  --column: string
  --series                    # also return the per-observation drawdown series
]: any -> record {
  let v = (take-series (given $values $in) $column)
  let bad = ($v | enumerate | where {|x| $x.item <= 0.0 } | first)
  if $bad != null {
    error make { msg: $"drawdown needs a price or cumulative-growth series — every value must be > 0; element ($bad.index) is ($bad.item)" }
  }

  # running peak, then the drawdown at each point
  let peaks = ($v | reduce --fold [] {|x, acc|
    let prev = (if ($acc | is-empty) { $x } else { ([($acc | last) $x] | math max) })
    $acc | append $prev
  })
  let dd = ($v | enumerate | each {|e| ($e.item / ($peaks | get $e.index)) - 1.0 })

  let trough = ($dd | enumerate | sort-by item | first | get index)
  let trough_peak = ($peaks | get $trough)
  let peak = ($v | enumerate | where {|e| $e.item == $trough_peak and $e.index <= $trough } | last | get index)
  let recovery = ($v | enumerate | where {|e| $e.index > $trough and $e.item >= $trough_peak } | first)

  (defined {
    max: ($dd | math min)
    peak_index: $peak
    trough_index: $trough
    recovery_index: (if $recovery == null { null } else { $recovery.index })
    decline: ($trough - $peak)
    total: (if $recovery == null { null } else { $recovery.index - $peak })
    current: ($dd | last)
    values: (if $series { $dd } else { null })
  } {
    kind: "drawdown"
    input: "prices or cumulative growth — all values > 0"
    max: "most negative peak-to-trough return; recovery_index and total are null while unrecovered"
    indices: "0-based positions in the input; in observations, not dates"
    observations: ($v | length)
  })
}

# value at risk (VaR) — not variance. variance is `series stats`.
export def var [
  values?: list<float>      # the return series, or prices with --from prices
  --level: float = 0.95     # confidence level, e.g. 0.95
  --from: string = "returns"
  --method: string = "log"  # used only when --from prices
  --column: string
]: any -> record {
  if $level <= 0.0 or $level >= 1.0 {
    error make { msg: $"level must be in (0, 1), got ($level)" }
  }
  let raw = (take-series (given $values $in) $column)
  let src = (check-from $from)
  let r = (resolve-returns $raw $src $method)
  if ($r | length) < 2 {
    error make { msg: $"need at least 2 returns, got ($r | length)" }
  }

  let q = (quantile $r (1.0 - $level))
  let tail = ($r | where {|x| $x <= $q })

  (defined {
    var: (0.0 - $q)
    cvar: (if ($tail | is-empty) { null } else { 0.0 - ($tail | math avg) })
    threshold: $q
    level: $level
  } {
    kind: "value-at-risk"
    method: "historical — the empirical quantile of the observed returns"
    quantile: "linear interpolation (type 7)"
    sign: "positive number = a loss; a negative value means the level is exceeded by the median outcome"
    horizon: "one period — the returns' own period. no sqrt-time scaling is applied"
    tail_observations: ($tail | length)
    observations: ($r | length)
  })
}

# where the most recent observation sits in the series' own history
#
# this is the plainest reading of "what is happening now": not the value on its own, which
# means nothing without its history, but the value's position in the distribution the
# series has actually shown. the arithmetic is here rather than in a caller's head because
# a percentile worked out mentally is a number nobody can reproduce.
export def position [
  values?: list<float>      # the series; omit it to pipe instead
  --column: string
]: any -> record {
  let x = (take-series (given $values $in) $column)
  let n = ($x | length)
  if $n < 2 {
    error make { msg: $"need at least 2 observations to place the latest one, got ($n)" }
  }

  let latest = ($x | last)
  let mt = (moments $x)
  let sd = (sd-of $x false)
  let mn = ($x | math min)
  let mx = ($x | math max)
  let range = ($mx - $mn)

  (defined {
    latest: $latest
    previous: ($x | get ($n - 2))
    change: ($latest - ($x | get ($n - 2)))
    percentile: (($x | where {|v| $v <= $latest } | length | into float) / ($n | into float))
    zscore: (if $sd == null or $sd == 0.0 { null } else { ($latest - $mt.mean) / $sd })
    mean: $mt.mean
    min: $mn
    max: $mx
    observations: $n
    range_position: (if $range == 0.0 { null } else { ($latest - $mn) / $range })
  } {
    kind: "position"
    percentile: "the share of the series at or below the latest observation — an empirical rank, with no distributional assumption. it is 1.0 when the latest reading is the highest on record"
    zscore: "sample sd (÷ n−1); null when the series is constant, where it would be a division by zero dressed up as a number"
    range_position: "0.0 at the historical low, 1.0 at the historical high; null when the series is constant"
    change: "the latest observation minus the one before it, in the series' own units"
    observations: $n
  })
}
