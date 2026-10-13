#!/usr/bin/env nu
# options.nu — the OCC symbol decoder, which is the whole hermetic surface
#
# a chain is fetched, so the parser is what can be checked without one — and the parser is
# where a bug is silent: a mis-sliced date still produces a well-formed string.

use ./harness.nu *
use ./../apps/financial/options.nu

let results = [
  (case "occ: a symbol decodes into root, expiry, kind and strike" {
    let o = (options occ SPX261016C00200000)
    (eq "occ: a symbol decodes into root, expiry, kind and strike" [$o.root $o.expiry $o.kind $o.strike] ["SPX" "2026-10-16" "call" 200.0])
  })

  (case "occ: the strike is divided back out of the eight digits" {
    # the eight digits carry strike × 1000. skipping the division yields a 200,000-strike
    # contract, which is a valid-looking number and a wrong one
    (eq "occ: the strike is divided back out of the eight digits" (options occ "AAPL260116P00150000" | get strike) 150.0)
  })

  (case "occ: P decodes as a put" {
    (eq "occ: P decodes as a put" (options occ "SPX261016P00700000" | get kind) "put")
  })

  (case "occ: the date is four digits of year, not five" {
    # `str substring 0..2` is THREE characters in nushell, and produced "20261-101-16"
    (eq "occ: the date is four digits of year, not five" (options occ "SPX261016C00200000" | get expiry | str length) 10)
  })

  (case "occ: something that is not an OCC symbol is refused, not half-decoded" {
    (throws "occ: something that is not an OCC symbol is refused, not half-decoded" { options occ "NOTASYMBOL" })
  })
]

emit $results
