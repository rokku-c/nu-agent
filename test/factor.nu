#!/usr/bin/env nu
# factor.nu — what can be checked without a market
#
# thin on purpose, and the thinness is honest: the module's logic runs on price history, so
# the testable-without-a-network surface is the catalogue and the guards. `factor test` is
# exercised against live history outside this suite.

use ./harness.nu *
use ./../apps/financial/factor.nu

let results = [
  (case "kinds: every factor is named and says what it needs" {
    let k = (factor kinds)
    (eq "kinds: every factor is named and says what it needs" ($k | get kind | sort) ["momentum" "reversal" "sma-gap" "volatility"])
  })

  (case "kinds: each factor is a definition with one parameter, not a search" {
    # deliberately few and unfitted: a result should say something about the definition
    # rather than about how many variants were tried
    (eq "kinds: each factor is a definition with one parameter, not a search" (factor kinds | get needs | uniq) ["lookback"])
  })

  (case "guard: a forward horizon below one bar is refused" {
    (throws "guard: a forward horizon below one bar is refused" {
      factor test sh000001 --forward 0
    })
  })

  (case "guard: too little history for the lookback and the horizon is refused, not fudged" {
    # a factor needing 200 bars and a 50-bar horizon cannot be measured on 250 bars, and
    # quietly shrinking the window would make the result about a different factor
    (throws "guard: too little history for the lookback and the horizon is refused, not fudged" {
      factor test sh000001 --lookback 400 --forward 50 --limit 10
    })
  })

  (case "guard: an unknown factor name is refused" {
    (throws "guard: an unknown factor name is refused" {
      factor test sh000001 --kind astrology
    })
  })
]

emit $results
