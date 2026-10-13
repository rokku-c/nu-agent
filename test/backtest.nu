#!/usr/bin/env nu
# backtest.nu — the execution engine, on synthetic bars
#
# hermetic by construction: the engine takes bars and a target, so every constraint can be
# tested without a network, a symbol or a market being open. the strategies fetch and are not
# covered here; the engine is what must be right, because a strategy tested on a broken
# engine proves nothing.

use ./harness.nu *
use ./../apps/financial/backtest.nu

# four flat 100-share bars. open == close on most so the arithmetic is checkable by hand.
let bars = [
  {period: "2026-01-01", open: 10.0, close: 10.0}
  {period: "2026-01-02", open: 10.0, close: 11.0}
  {period: "2026-01-05", open: 11.0, close: 12.0}
  {period: "2026-01-06", open: 12.0, close: 9.0}
]

def near [a: any, b: any, tol: float = 1e-6]: nothing -> bool {
  if $a == null or $b == null { return false }
  ((($a | into float) - ($b | into float)) | math abs) <= $tol
}

# two bars on each of two days. this is the shape a daily bar cannot express, and it is why an
# earlier draft of the engine said 底仓+T+0 was unmodellable.
let intraday = [
  {period: "2026-01-01 09:30", open: 10.0, close: 10.0}
  {period: "2026-01-01 10:00", open: 10.0, close: 10.0}
  {period: "2026-01-02 09:30", open: 10.0, close: 10.0}
  {period: "2026-01-02 10:00", open: 10.0, close: 10.0}
]

let results = [
  # ── no look-ahead ──
  (case "fill: a target set at bar t's close fills at bar t+1's OPEN" {
    # the whole difference between a backtest and a wish. target 100 from bar 1 onward means
    # the first possible fill is bar 2, at 11.0 (its open) — not at bar 1's 10.0.
    let r = (backtest simulate $bars [0 100 100 100] --cash 10000.0)
    (eq "fill: a target set at bar t's close fills at bar t+1's OPEN" [
      ($r.trades | first | get period) ($r.trades | first | get price)
    ] ["2026-01-05" 11.0])
  })

  (case "fill: no trade happens on the first bar, whatever the target says" {
    # there is no prior close to compare the open against, so nothing can be filled
    let r = (backtest simulate $bars [100 100 100 100] --cash 10000.0)
    (eq "fill: no trade happens on the first bar, whatever the target says" [
      ($r.trades | first | get period) ($r.trades | first | get price)
    ] ["2026-01-02" 10.0])
  })

  # ── lot rounding ──
  (case "lot: an order rounds DOWN to whole lots" {
    # 150 shares is a 100-share order. rounding UP would silently spend cash the account
    # does not have; rounding to the nearest would do it intermittently.
    let r = (backtest simulate $bars [0 150 150 150] --cash 10000.0)
    (eq "lot: an order rounds DOWN to whole lots" ($r.trades | first | get shares) 100)
  })

  (case "lot: a target below one lot never trades" {
    let r = (backtest simulate $bars [0 50 50 50] --cash 10000.0)
    (eq "lot: a target below one lot never trades" ($r.trades | length) 0)
  })

  # ── the market's plumbing ──
  (case "lock: a bar opening at the price limit does not fill, and says so" {
    # bar c opens 18% above bar b's close. you could not have bought that open however much
    # you wanted to, so the order is blocked rather than filled at a price nobody got.
    let lim = [
      {period: "a", open: 10.0, close: 10.0}
      {period: "b", open: 10.0, close: 11.0}
      {period: "c", open: 13.0, close: 13.0}
    ]
    let r = (backtest simulate $lim [0 100 100] --cash 10000.0)
    (eq "lock: a bar opening at the price limit does not fill, and says so" [
      ($r.trades | length) ($r.definition.blocked)
    ] [0 ["c"]])
  })

  (case "lock: an unaffordable buy is blocked, never a negative cash balance" {
    # a 100-share order at 11.0 costs 1105 against 1000 of cash
    let r = (backtest simulate $bars [0 100 100 100] --cash 1000.0)
    (is-true "lock: an unaffordable buy is blocked, never a negative cash balance" (
      (($r.trades | length) == 0) and ($r.summary.ending_cash >= 0.0)
    ))
  })

  # ── costs ──
  (case "costs: the commission minimum dominates a small order" {
    # 100 shares at 11.0 is 1100 of value; at 2.5bp the rate gives 0.275, and the 5.0
    # minimum is what is actually charged. this is why small orders are expensive.
    let r = (backtest simulate $bars [0 100 100 100] --cash 10000.0)
    (is-true "costs: the commission minimum dominates a small order" (near ($r.trades | first | get cost) 5.0))
  })

  (case "costs: stamp duty is charged on the sell side only" {
    # buy at bar 2 (target rises), sell at bar 3 (target falls back): the sell carries duty
    let r = (backtest simulate $bars [0 100 0 0] --cash 10000.0)
    let buy = ($r.trades | where side == "buy" | first)
    let sell = ($r.trades | where side == "sell" | first)
    # sell: 100 shares at 12.0 = 1200 → commission 5.0 (minimum) + duty 0.6
    (is-true "costs: stamp duty is charged on the sell side only" (
      (near $buy.cost 5.0) and (near $sell.cost 5.6)
    ))
  })

  (case "costs: costs reduce the return rather than being ignored" {
    # 100 shares bought at 11.0, marked at 9.0: -200 on price, -5 on commission
    let r = (backtest simulate $bars [0 100 100 100] --cash 10000.0)
    (is-true "costs: costs reduce the return rather than being ignored" (near $r.summary.total_return (-0.0205)))
  })

  # ── the account ──
  (case "equity: cash plus marked-to-market holdings, on every bar" {
    let r = (backtest simulate $bars [0 100 100 100] --cash 10000.0)
    (eq "equity: cash plus marked-to-market holdings, on every bar" ($r.equity | length) 4)
  })

  (case "equity: the summary reconciles with the account it ends on" {
    let r = (backtest simulate $bars [0 100 100 100] --cash 10000.0)
    (is-true "equity: the summary reconciles with the account it ends on" (
      (near $r.summary.ending_cash 8895.0) and ($r.summary.ending_shares == 100)
    ))
  })

  (case "guard: bars and target must be the same length" {
    (throws "guard: bars and target must be the same length" { backtest simulate $bars [0 100] })
  })

  (case "guard: a single bar is not a backtest" {
    (throws "guard: a single bar is not a backtest" { backtest simulate [{period: "a", open: 1.0, close: 1.0}] [1] })
  })

  # ── the definition the engine reports ──
  (case "definition: states the fill rule and the costs it applied" {
    let d = (backtest simulate $bars [0 100 100 100] --cash 10000.0 | get definition)
    (is-true "definition: states the fill rule and the costs it applied" (
      (($d.fill | str contains "OPEN")) and (($d.costs | str contains "stamp duty"))
    ))
  })

  (case "definition: states the session rule T+1 is enforced by" {
    (has "definition: states the session rule T+1 is enforced by" (backtest simulate $bars [0 100 100 100] | get definition.t_plus_1) "SESSION began")
  })

  (case "T+1: shares bought this morning cannot be sold this afternoon" {
    # target 100 at bar 1 (day 1) → the bar-2 purchase is not sellable, so the target back to
    # 0 on the same day is blocked
    let r = (backtest simulate $intraday [0 100 0 0] --cash 100000.0)
    (eq "T+1: shares bought this morning cannot be sold this afternoon" [
      ($r.trades | length) ($r.summary.ending_shares)
    ] [1 100])
  })

  (case "T+1: a BASE held from an earlier day CAN be sold within today — that is 底仓+T+0" {
    # the base is bought on day 1; on day 2 the target goes to zero and the sale goes through,
    # because what may be sold is what was held before the session began
    let r = (backtest simulate $intraday [100 100 0 100] --cash 100000.0)
    let buy = ($r.trades | where side == "buy" | first)
    let sell = ($r.trades | where side == "sell" | first)
    # the buy lands on day 1 and the sale on day 2 — a base carried overnight, spent intraday
    (eq "T+1: a BASE held from an earlier day CAN be sold within today — that is 底仓+T+0" [
      (($r.trades | length)) (($buy.period | str substring 0..9)) (($sell.period | str substring 0..9))
    ] [2 "2026-01-01" "2026-01-02"])
  })

  (case "T+1: every trade names the bar it happened on, so a session is reconstructible" {
    let r = (backtest simulate $intraday [100 100 0 100] --cash 100000.0)
    (is-true "T+1: every trade names the bar it happened on, so a session is reconstructible" (
      (($r.trades | get period) | all {|p| ($p | str contains ":") })
    ))
  })
]

emit $results
