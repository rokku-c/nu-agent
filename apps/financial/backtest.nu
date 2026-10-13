# backtest.nu — execution simulation, with the market's plumbing modelled
#
#   use backtest.nu
#
#   backtest replay sh000001 --strategy buy-hold --limit 250
#   backtest replay sh000001 --strategy sma --fast 5 --slow 20 --limit 250
#   backtest replay sh000001 --strategy dca --every 21 --amount 10000 --limit 250
#
# ── what this is, and what it deliberately is not ──
# an EXECUTION simulator, not a signal generator. it answers "if I wanted this position on
# each bar, what would that actually have cost and returned" — which is where the A-share
# plumbing lives, and where most backtests quietly turn into fiction.
#
# the signal side is a separate concern and mostly unbuilt (`sma` and `dca` are the two
# simplest shapes). factor mining on top of an untrustworthy execution model is a
# high-volume hallucination factory, which is why the engine came first.
#
# ── the constraints modelled, and why each changes the answer ──
#   T+1 settlement   satisfied here by CONSTRUCTION, not by a counter: one order per bar,
#                    filled at the next bar's open, so a same-bar round trip is not
#                    expressible. what that means, honestly, is that this engine CANNOT
#                    model 底仓+T+0 — intraday round trips against a base position happen
#                    INSIDE a bar, and a daily bar does not contain them. an earlier draft
#                    carried a `sellable` counter, which was both wrong and a way of
#                    claiming a guarantee the bars cannot support.
#   price limits     a bar opening at the daily limit is locked — you cannot buy the
#                    limit-up open however much you wanted to.
#   lot size         orders round down to 100 shares.
#   stamp duty       sell side only.
#   commission       with a per-trade minimum, which dominates small orders.
#   no look-ahead    a target set at bar t's CLOSE fills at bar t+1's OPEN. that one-bar gap
#                    is the entire difference between a backtest and a wish.

use ./market.nu

const SIDE_BUY = "buy"
const SIDE_SELL = "sell"

# commission on a trade value, with the minimum that makes small orders expensive
def fee-of [gross: float, rate: float, min_fee: float]: nothing -> float {
  let c = ($gross * $rate)
  if $c < $min_fee { $min_fee } else { $c }
}

# ── the engine ──
# bars: [{period, open, close}] ascending. target: the share count wanted at the CLOSE of
# each bar. a target restated is not an order — only a change in the target trades.
export def simulate [
  bars: list<record>
  target: list<int>
  --cash: float = 100000.0
  --lot: int = 100
  --commission: float = 0.00025
  --min-commission: float = 5.0
  --stamp-duty: float = 0.0005
  --slippage: float = 0.0
  --limit-pct: float = 0.10
]: nothing -> record {
  if ($bars | length) < 2 { error make { msg: "need at least 2 bars" } }
  if ($bars | length) != ($target | length) {
    error make { msg: $"bars and target must be the same length, got ($bars | length) and ($target | length)" }
  }

  # the fold carries the whole account, because T+1 needs yesterday's buy and nothing else
  # does. every branch below is an expression — no early `return`, which is unreliable
  # inside a closure and is how the first draft of this file broke.
  let run = (
    $bars | enumerate | reduce --fold {
      cash: $cash
      held: 0
      sellable: 0
      equity: []
      trades: []
      blocked: []
    } {|e, acc|
      let i = $e.index
      let b = $e.item
      let close = ($b.close | into float)
      let open = ($b.open | into float)

      # ── T+1, done properly ──
      # what may be SOLD on this bar is what was held before the current SESSION began.
      # on daily bars every bar is a new session, so this reduces to the old behaviour; on
      # intraday bars it is the actual rule — a base position bought on an earlier day can be
      # sold and re-bought within today (which is what 底仓+T+0 IS), while shares bought this
      # morning cannot leave this afternoon. an earlier draft had no day boundary and could
      # only say the pattern was unmodellable.
      let day = ($b.period | str substring 0..9)
      let prev_day = (if $i == 0 { "" } else { ($bars | get ($i - 1) | get period | str substring 0..9) })
      let sellable = (if $i == 0 or $day != $prev_day { $acc.held } else { $acc.sellable })

      if $i == 0 {
        # the first bar only establishes a price: a fill needs a prior close to compare the
        # open against, and there is none yet
        {cash: $acc.cash, held: $acc.held, sellable: $acc.held,
         equity: ($acc.equity | append ($acc.cash + ($acc.held * $close))),
         trades: $acc.trades, blocked: $acc.blocked}
      } else {
        let prev_close = ($bars | get ($i - 1) | get close | into float)
        let locked = (($open / $prev_close - 1.0) | math abs) >= $limit_pct
        let want = ($target | get ($i - 1))
        let delta = ($want - $acc.held)
        # orders round DOWN to whole lots; a 150-share order is a 100-share order
        let lots = ((($delta | into float) / ($lot | into float)) | math floor | into int)
        let order = ($lots * $lot)

        if $locked {
          # the session opened at the limit: nobody could have traded it
          {cash: $acc.cash, held: $acc.held, sellable: $sellable,
           equity: ($acc.equity | append ($acc.cash + ($acc.held * $close))),
           trades: $acc.trades, blocked: ($acc.blocked | append $b.period)}
        } else if $order > 0 {
          let px = ($open * (1.0 + $slippage))
          let gross = (($order | into float) * $px)
          let fee = (fee-of $gross $commission $min_commission)
          if ($acc.cash - $gross - $fee) < 0.0 {
            # an unaffordable buy is a blocked order, never a negative cash balance
            {cash: $acc.cash, held: $acc.held, sellable: $sellable,
             equity: ($acc.equity | append ($acc.cash + ($acc.held * $close))),
             trades: $acc.trades, blocked: ($acc.blocked | append $b.period)}
          } else {
            let held2 = ($acc.held + $order)
            let cash2 = ($acc.cash - $gross - $fee)
            # a buy does NOT become sellable today: that is the whole of T+1
            {cash: $cash2, held: $held2, sellable: $sellable,
             equity: ($acc.equity | append ($cash2 + ($held2 * $close))),
             trades: ($acc.trades | append {period: $b.period, side: $SIDE_BUY, shares: $order, price: $px, cost: $fee}),
             blocked: $acc.blocked}
          }
        } else if $order < 0 {
          # only what was held on entry to this bar can go out; a same-bar buy-then-sell
          # is not expressible, so T+1 needs no separate bookkeeping here
          let want_sell = (0 - $order)
          # capped by what the SESSION started with, not by what is held now — the gap
          # between the two is exactly one same-day purchase
          let can_sell = ([$want_sell $sellable] | math min)
          if $can_sell == 0 {
            {cash: $acc.cash, held: $acc.held, sellable: $sellable,
             equity: ($acc.equity | append ($acc.cash + ($acc.held * $close))),
             trades: $acc.trades, blocked: ($acc.blocked | append $b.period)}
          } else {
            let px = ($open * (1.0 - $slippage))
            let gross = (($can_sell | into float) * $px)
            let fee = ((fee-of $gross $commission $min_commission) + ($gross * $stamp_duty))
            let held2 = ($acc.held - $can_sell)
            let cash2 = ($acc.cash + $gross - $fee)
            {cash: $cash2, held: $held2, sellable: ($sellable - $can_sell),
             equity: ($acc.equity | append ($cash2 + ($held2 * $close))),
             trades: ($acc.trades | append {period: $b.period, side: $SIDE_SELL, shares: (0 - $can_sell), price: $px, cost: $fee}),
             blocked: $acc.blocked}
          }
        } else {
          # the target is unchanged, so nothing trades
          {cash: $acc.cash, held: $acc.held, sellable: $sellable,
           equity: ($acc.equity | append ($acc.cash + ($acc.held * $close))),
           trades: $acc.trades, blocked: $acc.blocked}
        }
      }
    }
  )

  let eq = ($run.equity)
  let first = ($eq | first)
  let final = ($eq | last)
  # `math sum` refuses an empty list rather than returning 0, so the no-trade case is
  # branched explicitly instead of being papered over with a default
  let costs = (if ($run.trades | is-empty) { 0.0 } else { $run.trades | get cost | math sum })
  let turnover = (if ($run.trades | is-empty) { 0 } else { $run.trades | get shares | each {|s| $s | math abs } | math sum })

  {
    periods: ($bars | get period)
    equity: $eq
    trades: $run.trades
    target: $target
    summary: {
      bars: ($bars | length)
      trades: ($run.trades | length)
      blocked_orders: ($run.blocked | length)
      initial_equity: $first
      final_equity: $final
      total_return: (($final / $first) - 1.0)
      costs_paid: $costs
      turnover_shares: $turnover
      ending_cash: $run.cash
      ending_shares: $run.held
    }
    definition: {
      kind: "backtest"
      fill: "a target set at bar t's close fills at bar t+1's OPEN — the one-bar gap is the difference between a backtest and a wish"
      t_plus_1: "what may be sold on a bar is what was held before the current SESSION began. on daily bars that reduces to one order per bar; on intraday bars it is the real rule, so a base position can be sold and re-bought within a day (底仓+T+0) while shares bought this morning cannot leave this afternoon"
      locks: "a bar opening at or beyond --limit-pct from the previous close is treated as locked and does not fill"
      lot: $lot
      costs: $"commission at rate ($commission) with a per-trade minimum, on both sides; stamp duty at ($stamp_duty) on the sell side only"
      blocked: $run.blocked
    }
  }
}

# ── strategies ──
# each returns the share count wanted at the CLOSE of every bar. few and simple on purpose:
# the signal side is the part that is easy to fool yourself with, and it earns complexity
# one validated shape at a time.

# buy the largest whole-lot position the cash affords, then hold it
def strat-buy-hold [bars: list<record>, cash: float, lot: int]: nothing -> list<int> {
  let n = ($bars | length)
  let entry = (($bars | get 1 | get open | into float))
  let shares = (((($cash * 0.999) / $entry) / ($lot | into float)) | math floor | into int) * $lot
  (0..($n - 1)) | each {|i| if $i == 0 { 0 } else { $shares } }
}

# one lot while the fast average is above the slow one, flat otherwise
def strat-sma [bars: list<record>, lot: int]: nothing -> list<int> {
  let closes = ($bars | get close)
  let fast = 5
  let slow = 20
  (0..(($closes | length) - 1)) | each {|i|
    if $i < $slow { 0 } else {
      let f = (($closes | skip ($i - $fast + 1) | first $fast) | math avg)
      let s = (($closes | skip ($i - $slow + 1) | first $slow) | math avg)
      if $f > $s { $lot * 10 } else { 0 }
    }
  }
}

# add a fixed cash amount every N bars, rounded down to whole lots
def strat-dca [bars: list<record>, every: int, amount: float, lot: int]: nothing -> list<int> {
  let n = ($bars | length)
  (0..($n - 1)) | reduce --fold {shares: 0, out: []} {|i, acc|
    let add = (
      if $i == 0 or ($i mod $every) != 0 { 0 } else {
        let px = ($bars | get $i | get open | into float)
        (((($amount / $px) / ($lot | into float)) | math floor | into int) * $lot)
      }
    )
    let shares = ($acc.shares + $add)
    {shares: $shares, out: ($acc.out | append $shares)}
  } | get out
}

# ── the command ──

# replay one strategy over one instrument's history
export def replay [
  symbol: string            # sh000001, sh600519, …
  --strategy: string = "buy-hold"   # buy-hold | sma | dca
  --limit: int = 250
  --cash: float = 100000.0
  --lot: int = 100
  --every: int = 21         # dca: bars between contributions
  --amount: float = 10000.0 # dca: cash per contribution
  --stamp-duty: float = 0.0005
  --slippage: float = 0.0
]: nothing -> record {
  let records = (market history $symbol --limit $limit --fields "close,open")
  let closes = ($records | where series == $"($symbol):close")
  let bars = (
    $closes
    | each {|c|
        let o = ($records | where {|r| $r.series == $"($symbol):open" and $r.reference_period == $c.reference_period } | first)
        {period: $c.reference_period, close: $c.value, open: ($o | get --optional value | default $c.value)}
      }
    | sort-by period
  )

  let target = (
    if $strategy == "buy-hold" {
      strat-buy-hold $bars $cash $lot
    } else if $strategy == "sma" {
      strat-sma $bars $lot
    } else if $strategy == "dca" {
      strat-dca $bars $every $amount $lot
    } else {
      error make { msg: $"unknown strategy '($strategy)': use buy-hold, sma or dca" }
    }
  )

  simulate $bars $target --cash $cash --lot $lot --stamp-duty $stamp_duty --slippage $slippage
  | insert symbol $symbol
  | insert strategy $strategy
}
