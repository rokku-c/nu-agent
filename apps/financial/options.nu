# options.nu — derivatives: an option chain, and the readings that live inside it
#
#   use options.nu
#
#   options occ SPX261016C00200000          # decode an OCC symbol
#   options chain _SPX --expiry 2026-10-16  # the contracts
#   options term _SPX                       # at-the-money implied vol, by expiry
#   options implied-move _SPX               # what the option market itself expects
#
# ── the one idea this module is built on ──
# an option PRICE is not the interesting number; the implied volatility behind it is. price
# mixes a payout with a level of the underlying that moves, and only the vol is comparable
# across strikes and days. so everything here reports IV, and the prices are the raw material.
#
# and a single IV is not the interesting number either. what a derivatives desk actually reads
# is the SHAPE: the term structure across expiries, and the skew across strikes. both are
# reported here, because a flat number hides exactly the part that carries information.
#
# ── the reading worth having most ──
# `options implied-move` returns the market's own distribution for a horizon — the at-the-money
# straddle over spot. it is a forecast published every day by people with money at stake, and
# it is the honest benchmark for anything in the prediction archive: if a stated view is not
# better than the straddle, it is not a view.
#
# ── what a chain is not ──
# a chain is a CROSS-SECTION at an instant, not a series over periods. so these commands
# return tables of contracts rather than the point-in-time records everything else uses — the
# record shape is for a quantity tracked through time, and pretending a chain is one would
# force a shape onto it that does not fit. what IS a series is the derived reading, and those
# carry their retrieval time.
#
# source: CBOE's public delayed-quote API. keyless, official, and delayed — the quotes are
# not live, which is fine for a shape and useless for a fill.

use ./cache.nu

const CBOE_CHAIN = "https://cdn.cboe.com/api/global/delayed_quotes/options"

# ── the one parser ──
#
# OCC symbols pack everything into one string: root, yymmdd, C/P, and the strike times 1000
# in eight digits. `SPX261016C00200000` is the SPX 2026-10-16 200 call — and the strike has
# to be divided back out, which is the step that silently produces a 200,000-strike contract
# if it is skipped.
export def occ [symbol: string]: nothing -> record {
  let m = ($symbol | str replace -r '^([A-Z0-9]+?)(\d{6})([CP])(\d{8})$' '$1|$2|$3|$4')
  let parts = ($m | split row "|")
  if ($parts | length) != 4 {
    error make { msg: $"cannot read '($symbol)' as an OCC symbol — expected a root, yymmdd, C or P, and an 8-digit strike" }
  }
  # `str substring a..b` includes both ends (measured), so a two-character slice starting at
  # i is i..(i+1). the inclusive reading produced "20261-101-16" here rather than a crash.
  let d = ($parts | get 1)
  let expiry = $"20($d | str substring 0..1)-($d | str substring 2..3)-($d | str substring 4..5)"
  {
    root: ($parts | get 0)
    expiry: $expiry
    kind: (if ($parts | get 2) == "C" { "call" } else { "put" })
    strike: ((($parts | get 3) | into int) / 1000 | into float)
  }
}

# ── fetching ──

def fetch-chain [symbol: string]: nothing -> record {
  let url = $"($CBOE_CHAIN)/($symbol).json"
  let r = (cache fetch $url --source cboe --header {User-Agent: "Mozilla/5.0"} --ttl 15min)
  if (($r.payload | describe) | str starts-with "string") {
    error make { msg: $"no chain for ($symbol) — CBOE publishes _SPX, _VIX and a few others under this path" }
  }
  $r.payload.data
}

# every contract, decoded. `iv` is the number worth looking at and it arrives as a FRACTION
# (0.18 is 18%), which is kept as-is and labelled rather than silently turned into percent.
def contracts [data: record]: nothing -> list<record> {
  $data.options | each {|o|
    let k = (occ $o.option)
    {
      root: $k.root
      expiry: $k.expiry
      kind: $k.kind
      strike: $k.strike
      bid: ($o | get --optional bid)
      ask: ($o | get --optional ask)
      iv: ($o | get --optional iv)
      delta: ($o | get --optional delta)
      open_interest: ($o | get --optional open_interest)
      volume: ($o | get --optional volume)
      theo: ($o | get --optional theo)
    }
  }
}

# the underlying, estimated from the chain itself: the strike of the call whose delta is
# closest to a half. the payload may carry a spot but this does not depend on the field being
# present or named the way it was last week.
def spot-of [cs: list<record>]: nothing -> any {
  let calls = ($cs | where kind == "call" and delta != null)
  if ($calls | is-empty) { return null }
  let atm = ($calls | each {|c| $c | insert d (($c.delta - 0.5) | math abs) } | sort-by d | first)
  $atm.strike
}

# ── commands ──

# the contracts, optionally narrowed to one expiry and a window of strikes
export def chain [
  symbol: string = "_SPX"
  --expiry: string         # e.g. 2026-10-16
  --around: float          # keep strikes within this much of spot
  --limit: int = 40
]: nothing -> any {
  let data = (fetch-chain $symbol)
  let cs = (contracts $data)
  let spot = (spot-of $cs)
  let narrowed = (
    $cs
    | where {|c| ($expiry == null or $c.expiry == $expiry) }
    | where {|c| ($around == null or (($c.strike - $spot) | math abs) <= $around) }
    | sort-by expiry strike
    | first $limit
  )
  {symbol: $symbol, retrieved: (date now | format date "%Y-%m-%dT%H:%M:%S"), spot_estimate: $spot, contracts: $narrowed}
}

# at-the-money implied vol by expiry — the term structure, which is the shape that carries
# information a single number does not
export def term [
  symbol: string = "_SPX"
]: nothing -> any {
  let cs = (contracts (fetch-chain $symbol))
  let spot = (spot-of $cs)
  if $spot == null { error make { msg: "no call side in the chain, so no spot can be estimated" } }
  let expiries = ($cs | get expiry | uniq | sort)
  $expiries
  | each {|e|
      let sub = ($cs | where expiry == $e and iv != null and iv > 0.0)
      let atm = ($sub | each {|c| $c | insert d (($c.strike - $spot) | math abs) } | sort-by d | first)
      if $atm == null { null } else { {expiry: $e, strike: $atm.strike, kind: $atm.kind, iv: $atm.iv, delta: $atm.delta} }
    }
  | compact
  | {symbol: $symbol, spot_estimate: $spot, atm_iv_by_expiry: $in, retrieved: (date now | format date "%Y-%m-%dT%H:%M:%S")}
}

# what the option market itself expects, per expiry: the at-the-money straddle over spot.
# this is a distribution the market publishes daily, and the benchmark any stated view has
# to beat to be a view rather than a mood.
export def "implied-move" [
  symbol: string = "_SPX"
  --expiry: string
]: nothing -> any {
  let cs = (contracts (fetch-chain $symbol))
  let spot = (spot-of $cs)
  if $spot == null { error make { msg: "no call side in the chain, so no spot can be estimated" } }
  let expiries = (if $expiry == null { $cs | get expiry | uniq | sort } else { [$expiry] })
  let rows = (
    $expiries | each {|e|
      let sub = ($cs | where expiry == $e)
      let call = ($sub | where kind == "call" | each {|c| $c | insert d (($c.strike - $spot) | math abs) } | sort-by d | first)
      let put = ($sub | where kind == "put" | each {|c| $c | insert d (($c.strike - $spot) | math abs) } | sort-by d | first)
      if $call == null or $put == null { null } else {
        let mid_c = (($call.bid + $call.ask) / 2.0)
        let mid_p = (($put.bid + $put.ask) / 2.0)
        let straddle = ($mid_c + $mid_p)
        {
          expiry: $e
          strike: $call.strike
          straddle_mid: $straddle
          implied_move: ($straddle / $spot)
          call_iv: $call.iv
          put_iv: $put.iv
          # puts bid over calls at the same moneyness is the crash premium, and its absence is
          # as informative as its presence
          skew: (if ($put.iv != null) and ($call.iv != null) { $put.iv - $call.iv } else { null })
        }
      }
    }
  ) | compact
  {
    symbol: $symbol
    spot_estimate: $spot
    retrieved: (date now | format date "%Y-%m-%dT%H:%M:%S")
    by_expiry: $rows
    definition: {
      implied_move: "the at-the-money straddle over spot, as a FRACTION (0.04 is 4%). the market's own expected absolute move to that expiry, from prices rather than words"
      spot_estimate: "the strike of the call whose delta is closest to a half, taken from the chain itself so this does not depend on a spot field being present or named the way it was last week"
      skew: "the at-the-money put iv minus the call iv. positive is the usual crash premium; a negative skew is worth noticing rather than smoothing over"
      quotes: "CBOE delayed quotes — good for a shape, useless for a fill"
    }
  }
}
