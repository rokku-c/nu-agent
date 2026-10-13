# factor.nu — mining a factor, and testing whether it is anything
#
#   use factor.nu
#
#   factor kinds
#   factor test sh000001 --kind momentum --lookback 20 --forward 5 --limit 500
#
# ── the point of this module is the TEST, not the factor ──
# a factor is easy to produce and almost impossible to believe. what this module exists to do
# is make the disbelief cheap: state the information coefficient, say how much of the sample
# it was measured on, split it in and out of sample, and then — the part most factor research
# skips — hand the signal to the backtest engine and report what it made AFTER costs.
#
# three things it refuses to let slide:
#
#   1. A raw IC is not money. knowing a number at t and being able to trade on it at t+1 for
#      a profit are different claims, and only the second one has a P&L. so the IC comes with
#      a net backtest beside it, on the same engine every strategy is measured on.
#
#   2. Overlapping forward returns SHRINK the sample. with an N-bar forward return sampled
#      every bar, consecutive observations share N-1 bars of their outcome. 500 observations
#      at a 20-bar horizon are not 500 independent draws — they are about 25. the module
#      reports the effective count next to the raw one, because the t-statistic everybody
#      quotes is computed on the wrong one.
#
#   3. An in-sample IC is a number, not evidence. the sample is split, and both halves are
#      reported. a factor that only works in the first half is a story about the first half.

use ./series.nu
use ./market.nu
use ./backtest.nu

# the factors this knows. deliberately few, and none of them fitted: each is a definition
# from the literature with one parameter, so a result says something about the definition
# rather than about a search.
export def kinds []: nothing -> table {
  [
    {kind: "momentum"   needs: "lookback" note: "the trailing lookback-bar return — buy what has gone up"}
    {kind: "reversal"   needs: "lookback" note: "the NEGATIVE of the trailing lookback-bar return — buy what has gone down"}
    {kind: "volatility" needs: "lookback" note: "the trailing sd of one-bar returns — a risk measure used as a factor"}
    {kind: "sma-gap"    needs: "lookback" note: "close / trailing mean − 1, how far price sits from its own average"}
  ]
}

# factor values, aligned so index i can be paired with the return that FOLLOWS it.
# the first `lookback` entries are null: a factor that needs 20 bars of history is undefined
# on bar 3, and carrying a value there would be inventing one.
def values [closes: list<float>, kind: string, lookback: int]: nothing -> list<any> {
  let n = ($closes | length)
  (0..($n - 1)) | each {|i|
    if $i < $lookback { null } else {
      let window = ($closes | skip ($i - $lookback + 1) | first $lookback)
      if $kind == "momentum" {
        (($closes | get $i) / ($window | first)) - 1.0
      } else if $kind == "reversal" {
        0.0 - ((($closes | get $i) / ($window | first)) - 1.0)
      } else if $kind == "volatility" {
        ($window | series returns | series volatility --annualize 0 | get value)
      } else if $kind == "sma-gap" {
        (($closes | get $i) / ($window | math avg)) - 1.0
      } else {
        error make { msg: $"unknown factor '($kind)': run `factor kinds`" }
      }
    }
  }
}

# ordinal ranks, ties broken by position rather than averaged. averaging ties is the textbook
# choice and would be better; it is not done here, and saying so is worth more than a silent
# approximation that a reader would assume away.
def rank [x: list<float>]: nothing -> list<float> {
  let order = ($x | enumerate | sort-by item)
  let n = ($x | length)
  $order | enumerate | each {|e| {i: $e.item.index, r: ($e.index | into float)}} | sort-by i | get r
}

# Spearman: Pearson on the ranks. robust to the monotone-but-nonlinear relationship that raw
# returns have with almost everything.
def spearman [x: list<float>, y: list<float>]: nothing -> any {
  if ($x | length) < 3 { return null }
  let rx = (rank $x)
  let ry = (rank $y)
  let mx = ($rx | math avg)
  let my = ($ry | math avg)
  let dx = ($rx | each {|v| $v - $mx })
  let dy = ($ry | each {|v| $v - $my })
  let num = (($dx | enumerate | each {|e| $e.item * ($dy | get $e.index) }) | math sum)
  let den = ((($dx | each {|v| $v * $v } | math sum) * ($dy | each {|v| $v * $v } | math sum)) | math sqrt)
  if $den == 0.0 { null } else { $num / $den }
}

# ── commands ──

# note: an earlier `values-of` (the factor as a record series) was removed — it indexed the
# factor with `get` and no `--optional`, so a factor series shorter than the bar series
# crashed it with `access_beyond_end`. `factor test` is the command that matters and it never
# had that bug. a convenience that is broken is worse than one that does not exist.

# the test. IC in and out of sample, the effective sample size, the quantile spread, and a
# net backtest of the factor's own signal on the engine everything else is measured on.
export def test [
  symbol: string
  --kind: string = "momentum"
  --lookback: int = 20
  --forward: int = 5      # the horizon the factor is meant to predict
  --limit: int = 500
  --cash: float = 100000.0
  --lot: int = 100      # 100 for an A-share stock; an INDEX is not lot-traded, so pass 1
]: nothing -> record {
  if $forward < 1 { error make { msg: "--forward must be at least 1" } }
  let bars = (bars-of $symbol $limit)
  let closes = ($bars | get close)
  let n = ($closes | length)
  if $n < ($lookback + $forward + 10) {
    error make { msg: $"not enough history: ($n) bars for a ($lookback)-bar factor and a ($forward)-bar forward return" }
  }

  let f = (values $closes $kind $lookback)

  # pair each factor value at t with the return from t to t+forward, dropping the tail where
  # the forward return does not exist yet
  let pairs = (
    (0..($n - $forward - 1))
    | each {|i|
        # a source can return fewer bars than asked for, so every lookup is optional and a
        # missing one drops the pair rather than raising — the sample is whatever it is, and
        # silently padding it would be worse than a smaller one
        let fv = ($f | get --optional $i)
        let c0 = ($closes | get --optional $i)
        let c1 = ($closes | get --optional ($i + $forward))
        if $fv == null or $c0 == null or $c1 == null { null } else {
          {i: $i, period: ($bars | get $i | get period), f: $fv, fwd: (($c1 / $c0) - 1.0)}
        }
      }
    | compact
  )

  let m = ($pairs | length)
  # with overlapping windows consecutive outcomes share bars, so the independent count is the
  # horizon's worth of overlap smaller. quoting the raw count would overstate the evidence.
  let effective = (($m | into float) / ($forward | into float) | math floor | into int)

  let half = (($m | into float) / 2.0 | math floor | into int)
  let first = ($pairs | first $half)
  let second = ($pairs | skip $half)

  # the factor's own signal, traded: long when the factor is in the top half of its own
  # history, flat otherwise. the target is in shares so the engine's costs and lots apply.
  let factor_series = ($pairs | each {|p| $p.f})
  let med = ($factor_series | sort | get ($half - 1))
  let target = (
    $bars | enumerate | each {|e|
        let p = ($pairs | where i == $e.index | first)
        if $p == null { 0 } else if ($p.f > $med) { 100 } else { 0 }
      }
  )
  # the target is in shares so the engine's lot rounding applies; 100 shares of an index
  # at 3800 points is unaffordable, which is why --lot exists and why an index wants 1
  let target = ($target | each {|t| if $t > 0 { $lot } else { 0 } })
  let bt = (backtest simulate $bars $target --cash $cash --lot $lot)

  # nushell does not allow `let` inside a parenthesised subexpression, so the spread is
  # computed here rather than inline in the record below
  let hi = ($pairs | where {|p| $p.f > $med })
  let lo = ($pairs | where {|p| $p.f <= $med })
  let spread = (
    if ($hi | is-empty) or ($lo | is-empty) { null } else {
      {
        high_mean_forward: ($hi | get fwd | math avg)
        low_mean_forward: ($lo | get fwd | math avg)
        spread: (($hi | get fwd | math avg) - ($lo | get fwd | math avg))
      }
    }
  )

  {
    symbol: $symbol
    factor: $kind
    lookback: $lookback
    forward: $forward
    ic: (spearman ($pairs | get f) ($pairs | get fwd))
    ic_first_half: (spearman ($first | get f) ($first | get fwd))
    ic_second_half: (spearman ($second | get f) ($second | get fwd))
    observations: $m
    effective_observations: $effective
    quantile_spread: $spread
    traded: {
      trades: $bt.summary.trades
      total_return: $bt.summary.total_return
      costs_paid: $bt.summary.costs_paid
      note: "the factor's own signal through the execution engine: lot rounding, the commission minimum and the sell-side stamp duty all apply"
    }
    definition: {
      kind: "factor test"
      ic: "Spearman rank correlation between the factor at bar t and the return from t to t+forward bars. it measures a monotone relationship, so a nonlinear but real edge will understate here"
      effective_observations: $"($m) pairs at a ($forward)-bar horizon overlap, so they carry about ($effective) independent draws, not ($m). a t-statistic computed on the raw count is too large by roughly sqrt\(($forward))"
      split: "the first and second halves of the sample, reported separately — a factor that only works in one of them is a story about that half"
      costs: "in the traded block, not in the IC. an IC is a correlation; money requires a portfolio, costs and capacity"
    }
  }
}

# one instrument's daily bars, ascending, with open and close
def bars-of [symbol: string, limit: int]: nothing -> list<record> {
  let records = (market history $symbol --limit $limit --fields "close,open")
  let closes = ($records | where series == $"($symbol):close")
  if ($closes | is-empty) { error make { msg: $"no history for ($symbol)" } }
  ($closes | each {|c|
      let o = ($records | where {|r| $r.series == $"($symbol):open" and $r.reference_period == $c.reference_period } | first)
      {period: $c.reference_period, close: $c.value, open: ($o | get --optional value | default $c.value)}
    } | sort-by period)
}
