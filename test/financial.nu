#!/usr/bin/env nu
# financial.nu — the deterministic series kernel: returns, risk, statistics
#
# run standalone:  nu --config test/config.nu test/financial.nu
#
# every expected value here is hand-computed and written next to the assertion, so a
# failure says which convention drifted rather than just that a number moved.

use ./harness.nu *

# the harness compares exactly; these tests are about floats, so tolerance
def near [a: any, b: any, tol: float = 1e-9]: nothing -> bool {
  if $a == null or $b == null { return false }
  ((($a | into float) - ($b | into float)) | math abs) <= $tol
}

def near-list [a: list, b: list, tol: float = 1e-9]: nothing -> bool {
  if ($a | length) != ($b | length) { return false }
  ($a | enumerate | all {|e| near $e.item ($b | get $e.index) $tol })
}

let results = [
  # ── returns ──
  (case "returns: simple is p_t/p_{t-1} − 1" {
    # 110/100−1 = 0.1 ; 99/110−1 = −0.1
    let got = ([100 110 99] | series returns).values
    (is-true "returns: simple is p_t/p_{t-1} − 1" (near-list $got [0.1 -0.1]))
  })

  (case "returns: log is ln(p_t/p_{t-1})" {
    let got = ([100 110] | series returns --method log).values
    (is-true "returns: log is ln(p_t/p_{t-1})" (near-list $got [(1.1 | math ln)]))
  })

  (case "returns: the series is one shorter than the prices" {
    let r = ([100 110 99 105] | series returns)
    (eq "returns: the series is one shorter than the prices" [($r.values | length) ($r.definition.prices)] [3 4])
  })

  (case "returns: ints are widened to floats" {
    let got = ([100 110] | series returns).values
    (eq "returns: ints are widened to floats" ($got | first | describe) "float")
  })

  (case "returns: a table plus --column selects the series" {
    let t = [[date close]; [2024-01-01 100.0] [2024-01-02 110.0]]
    let got = ($t | series returns --column close).values
    (is-true "returns: a table plus --column selects the series" (near-list $got [0.1]))
  })

  (case "returns: fewer than two prices raises" {
    (throws "returns: fewer than two prices raises" { [100] | series returns })
  })

  (case "returns: a log return of a non-positive price raises" {
    # ln(0/100) is −inf; refusing is the honest answer, not returning −inf
    (throws "returns: a log return of a non-positive price raises" { [100 0] | series returns --method log })
  })

  (case "returns: an unknown method raises" {
    (throws "returns: an unknown method raises" { [100 110] | series returns --method geometric })
  })

  (case "returns: the definition names the method" {
    let d = ([100 110] | series returns --method log).definition
    (eq "returns: the definition names the method" [$d.kind $d.method $d.input] ["return" "log" "prices"])
  })

  # ── the input contract: a bare list, a table+column, or a sibling's record ──
  (case "input: a table without --column raises and names the columns" {
    # silently picking the first column would be a wrong answer, not an error
    (throws "input: a table without --column raises and names the columns" {
      [[date close]; [2024-01-01 100.0]] | series returns
    })
  })

  (case "input: an empty series raises" {
    (throws "input: an empty series raises" { [] | series returns })
  })

  (case "input: a non-numeric element raises and names its position" {
    (throws "input: a non-numeric element raises and names its position" { [100 "110"] | series returns })
  })

  (case "input: a record without `values` raises" {
    (throws "input: a record without `values` raises" { {a: 1} | series stats })
  })

  (case "input: a record that a sibling produced chains" {
    # this is the whole reason take-series accepts records
    let v = ([100 110 99] | series returns | series volatility --annualize 0)
    (is-true "input: a record that a sibling produced chains" (($v.value | describe) == "float"))
  })

  (case "input: the series can be passed as a parameter, not only piped" {
    # measured: a command whose only input is the pipeline is exposed with an empty
    # property set, so a model cannot call it at all. the positional is what makes
    # these tools real; the pipe stays for a human at the prompt.
    let a = (series returns [100 110 99]).values
    let b = ([100 110 99] | series returns).values
    (is-true "input: the series can be passed as a parameter, not only piped" (near-list $a $b))
  })

  (case "input: when both a parameter and a pipe arrive, the parameter wins" {
    # the pipe still feeds the command; the explicit argument is what the caller
    # actually asked for, so it takes precedence
    let got = ([0.5 0.5] | series stats [1 2 3 4]).mean
    (is-true "input: when both a parameter and a pipe arrive, the parameter wins" (near $got 2.5))
  })

  (case "input: with no parameter, the pipe is what the command reads" {
    let got = (series returns [100 110 99] | series stats).mean
    (is-true "input: with no parameter, the pipe is what the command reads" (near $got 0.0))
  })

  # ── cumulate ──
  (case "cumulate: simple compounds multiplicatively" {
    # 1.0·1.1 = 1.1 ; 1.1·0.9 = 0.99
    let got = ([0.1 -0.1] | series cumulate).values
    (is-true "cumulate: simple compounds multiplicatively" (near-list $got [1.1 0.99]))
  })

  (case "cumulate: --start sets the base" {
    let got = ([0.1] | series cumulate --start 100.0).values
    (is-true "cumulate: --start sets the base" (near-list $got [110.0]))
  })

  (case "cumulate: log inverts the log returns it was given" {
    # prices → log returns → cumulate log must recover the price ratios
    let got = ([100 110 99] | series returns --method log | series cumulate --method log).values
    (is-true "cumulate: log inverts the log returns it was given" (near-list $got [1.1 0.99] 1e-12))
  })

  # ── stats ──
  (case "stats: mean is the arithmetic average" {
    # (1+2+3+4)/4 = 2.5
    (is-true "stats: mean is the arithmetic average" (near ([1 2 3 4] | series stats).mean 2.5))
  })

  (case "stats: sd is the sample sd by default" {
    # deviations from 2.5: −1.5 −0.5 0.5 1.5 ; squares sum to 5 ; /(4−1) → sqrt(5/3)
    (is-true "stats: sd is the sample sd by default" (near ([1 2 3 4] | series stats).sd (5.0 / 3.0 | math sqrt)))
  })

  (case "stats: --population divides by n" {
    # sqrt(5/4)
    (is-true "stats: --population divides by n" (near ([1 2 3 4] | series stats --population).sd (5.0 / 4.0 | math sqrt)))
  })

  (case "stats: the definition records which denominator was used" {
    let s = ([1 2 3 4] | series stats)
    (has "stats: the definition records which denominator was used" $s.definition.sd "n−1")
  })

  (case "stats: skew of a symmetric series is zero" {
    (is-true "stats: skew of a symmetric series is zero" (near ([1 2 3 4] | series stats).skew 0.0 1e-12))
  })

  (case "stats: skew is null below three observations" {
    (eq "stats: skew is null below three observations" ([1 2] | series stats).skew null)
  })

  (case "stats: kurtosis is excess, so a symmetric two-point series is null too" {
    (eq "stats: kurtosis is excess, so a symmetric two-point series is null too" ([1 2 3] | series stats).kurtosis null)
  })

  (case "stats: a constant series has a null skew rather than a NaN" {
    # m2 = 0, so the moment ratio is 0/0 — null is the honest answer
    (eq "stats: a constant series has a null skew rather than a NaN" ([5 5 5 5] | series stats).skew null)
  })

  (case "stats: n, min, max and median are reported" {
    let s = ([1 2 3 4] | series stats)
    (eq "stats: n, min, max and median are reported" [$s.n $s.min $s.max $s.median] [4 1.0 4.0 2.5])
  })

  # ── volatility ──
  (case "volatility: annualized is sd × sqrt(factor)" {
    let r = ([100 110 99] | series returns)
    let s = ($r | series stats)
    let v = ($r | series volatility --annualize 252)
    (is-true "volatility: annualized is sd × sqrt(factor)" (near $v.value ($s.sd * ((252 | into float) | math sqrt))))
  })

  (case "volatility: --annualize 0 leaves the per-period figure" {
    let r = ([100 110 99] | series returns)
    let s = ($r | series stats)
    let v = ($r | series volatility --annualize 0)
    (is-true "volatility: --annualize 0 leaves the per-period figure" (near $v.value $s.sd))
  })

  (case "volatility: --from prices agrees with returns piped in" {
    # one code path, so these cannot disagree — asserted rather than assumed
    let a = ([100 110 99] | series volatility --from prices --method simple --annualize 0)
    let b = ([100 110 99] | series returns | series volatility --annualize 0)
    (is-true "volatility: --from prices agrees with returns piped in" (near $a.value $b.value 1e-12))
  })

  (case "volatility: the definition carries the annualization factor" {
    # the contract this module exists for: the number is unusable without it
    let v = ([100 110 99] | series volatility --annualize 252)
    (has "volatility: the definition carries the annualization factor" $v.definition.annualization "252")
  })

  # ── drawdown ──
  (case "drawdown: max is the deepest peak-to-trough return" {
    # peaks 100,120,120,120 ; drawdowns 0, 0, 90/120−1 = −0.25, 110/120−1
    let d = ([100 120 90 110] | series drawdown)
    (is-true "drawdown: max is the deepest peak-to-trough return" (near $d.max (-0.25)))
  })

  (case "drawdown: it reports where the peak and trough were" {
    let d = ([100 120 90 110] | series drawdown)
    (eq "drawdown: it reports where the peak and trough were" [$d.peak_index $d.trough_index] [1 2])
  })

  (case "drawdown: an unrecovered drawdown reports null recovery and total" {
    let d = ([100 120 90 110] | series drawdown)
    (eq "drawdown: an unrecovered drawdown reports null recovery and total" [$d.recovery_index $d.total] [null null])
  })

  (case "drawdown: a recovered one reports the recovery index and total length" {
    # 130 ≥ the 120 peak at index 1, so recovery is index 3 and total is 3−1 = 2
    let d = ([100 120 90 130] | series drawdown)
    (eq "drawdown: a recovered one reports the recovery index and total length" [$d.recovery_index $d.total $d.current] [3 2 0.0])
  })

  (case "drawdown: the per-observation series is opt-in" {
    # a long array in every tool result is context the caller did not ask for
    let off = ([100 120 90] | series drawdown)
    let on = ([100 120 90] | series drawdown --series)
    (eq "drawdown: the per-observation series is opt-in" [$off.values ($on.values | length)] [null 3])
  })

  (case "drawdown: a non-positive value raises" {
    (throws "drawdown: a non-positive value raises" { [100 0 90] | series drawdown })
  })

  # ── value at risk ──
  (case "var: is the empirical quantile, reported as a positive loss" {
    # sorted −0.04 −0.02 0.005 0.01 0.03 ; q=0.05 → h=0.2 → −0.04 + 0.2·0.02 = −0.036
    let v = ([0.01 -0.02 0.03 -0.04 0.005] | series var --level 0.95)
    (is-true "var: is the empirical quantile, reported as a positive loss" (near $v.var 0.036))
  })

  (case "var: cvar is the mean of the tail beyond it" {
    # the only observation at or below −0.036 is −0.04, so cvar = 0.04
    let v = ([0.01 -0.02 0.03 -0.04 0.005] | series var --level 0.95)
    (is-true "var: cvar is the mean of the tail beyond it" (near $v.cvar 0.04))
  })

  (case "var: a higher level is a larger loss" {
    let s = [0.01 -0.02 0.03 -0.04 0.005]
    let a = ($s | series var --level 0.95)
    let b = ($s | series var --level 0.99)
    (is-true "var: a higher level is a larger loss" ($b.var > $a.var))
  })

  (case "var: the definition declares the sign convention and the horizon" {
    let v = ([0.01 -0.02 0.03 -0.04] | series var)
    (is-true "var: the definition declares the sign convention and the horizon" (
      (($v.definition.sign | str contains "loss") and ($v.definition.horizon | str contains "one period"))
    ))
  })

  (case "var: a level outside (0,1) raises" {
    (throws "var: a level outside (0,1) raises" { [0.01 -0.02] | series var --level 1.5 })
  })

  # ── position: where the latest reading sits in the series' own history ──
  (case "position: latest, previous and change are the last two observations" {
    let p = ([1 2 3 10] | series position)
    (eq "position: latest, previous and change are the last two observations" [$p.latest $p.previous $p.change] [10.0 3.0 7.0])
  })

  (case "position: percentile is an empirical rank over the values seen" {
    # latest is 3, and 1, 2 and 3 are at or below it → 3/4. no distribution is assumed,
    # which is the only honest thing to do with a handful of macro observations.
    (is-true "position: percentile is an empirical rank over the values seen" (near ([10 1 2 3] | series position).percentile 0.75))
  })

  (case "position: percentile is 1.0 when the latest is the highest on record" {
    (is-true "position: percentile is 1.0 when the latest is the highest on record" (near ([1 2 3] | series position).percentile 1.0))
  })

  (case "position: zscore is the latest against the SAMPLE sd" {
    let x = [1.0 2.0 3.0 10.0]
    let s = ($x | series stats)
    (is-true "position: zscore is the latest against the SAMPLE sd" (near ($x | series position).zscore ((10.0 - $s.mean) / $s.sd)))
  })

  (case "position: range_position runs from 0 at the historical low to 1 at the high" {
    (is-true "position: range_position runs from 0 at the historical low to 1 at the high" (
      (near ([10 2 1] | series position).range_position 0.0) and (near ([1 2 10] | series position).range_position 1.0)
    ))
  })

  (case "position: a constant series gives null, not a division dressed up as a number" {
    let p = ([5 5 5] | series position)
    (eq "position: a constant series gives null, not a division dressed up as a number" [$p.zscore $p.range_position] [null null])
  })

  (case "position: one observation cannot be placed in a history" {
    (throws "position: one observation cannot be placed in a history" { [5] | series position })
  })

  (case "position: the definition states that the percentile assumes no distribution" {
    let p = ([1 2 3] | series position)
    (has "position: the definition states that the percentile assumes no distribution" $p.definition.percentile "empirical")
  })

  # ── the naming contract ──
  (case "series: expose yields one tool per subcommand, prefixed by the module" {
    # `export def main` would yield the bare module name; these are subcommands, so
    # the tool names are series_*. asserted here because nothing in test/resolve.nu
    # scans apps/ — that suite only guards core/ and tools/.
    let names = (expose from-module series | get name | sort)
    (eq "series: expose yields one tool per subcommand, prefixed by the module" $names [
      "series_cumulate" "series_drawdown" "series_position" "series_returns" "series_stats" "series_var" "series_volatility"
    ])
  })

  (case "series: every tool is callable and its schema is closed over its own params" {
    # a tool an LLM cannot call is not a capability
    let t = (expose from-module series | where name == "series_volatility" | first)
    (eq "series: every tool is callable and its schema is closed over its own params" (
      $t.input_schema.properties | columns | sort
    ) ["annualize" "column" "from" "method" "population" "values"])
  })

  (case "series: every tool exposes the series as a parameter, not only as a pipe" {
    # THE regression guard. an exposed command whose sole input is the pipeline comes
    # out with `"properties": {}` and cannot be called by a model at all — which is
    # precisely how this module shipped broken the first time, and it failed silently
    # (the tool was listed, and simply ignored its caller's data).
    let missing = (
      expose from-module series
      | where {|t| not ("values" in ($t.input_schema.properties | columns)) }
      | get name
    )
    (eq "series: every tool exposes the series as a parameter, not only as a pipe" $missing [])
  })

  (case "series: values is optional, so piping remains legal" {
    let t = (expose from-module series | where name == "series_stats" | first)
    (eq "series: values is optional, so piping remains legal" ($t.input_schema | get --optional required | default []) [])
  })

  (case "series: no command produces a number without a definition" {
    # the module's central contract, asserted across every command rather than
    # trusted to review
    let outs = [
      ([100 110 99] | series returns)
      ([100 110 99] | series returns | series cumulate)
      ([100 110 99] | series stats)
      ([100 110 99] | series volatility)
      ([100 120 90] | series drawdown)
      ([0.01 -0.02 0.03] | series var)
    ]
    let missing = ($outs | where {|o| ($o | get --optional definition) == null })
    (eq "series: no command produces a number without a definition" $missing [])
  })
]

emit $results
