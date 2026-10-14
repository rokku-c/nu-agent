#!/usr/bin/env nu
# analyze-market.nu —— 分析近期市场情况
#   1) 本地取数（market）+ 本地计算（series），事实清单落盘 digest.json
#   2) 把清单交给 `agent` 写判断；agent 还能自己再调 market 去补数据
# 用法: nu analyze-market.nu [--dry-run] [--out digest.json]
#
# 注意：`nu -c` 或脚本方式启动的 nu 子进程不读 config.nu，自定义命令一个都不在，
# 所以必须显式 use（路径即 install.nu 写进 config.nu 的那几个）。

use /Volumes/CaseSensitive/macOS/repos/nu-agent/apps/financial/series.nu
use /Volumes/CaseSensitive/macOS/repos/nu-agent/apps/financial/market.nu
use /Volumes/CaseSensitive/macOS/repos/nu-agent/core/agent.nu

const TENORS = ["3 Mo" "2 Yr" "5 Yr" "10 Yr" "30 Yr"]

const EQUITIES = [
  {sym: "sh000001" name: "上证指数"}
  {sym: "sz399001" name: "深证成指"}
  {sym: "sh000300" name: "沪深300"}
  {sym: "sh600519" name: "贵州茅台"}
  {sym: "sz300750" name: "宁德时代"}
]

def r4 [x] { $x | into float | math round --precision 4 }

def ret-n [px: list<float>, back: int] {
  let n = ($px | length)
  ($px | last) / ($px | get ($n - 1 - $back)) - 1
}

def get-curve [] {
  $TENORS | each {|t|
    market curve --tenor $t --as state
    | select latest change percentile zscore min max range_position observations as_of
    | insert tenor $t
  }
}

def get-equities [] {
  $EQUITIES | each {|e|
    let h = (market history $e.sym --fields close --limit 130)
    let px = ($h | get value)
    let dd = (series drawdown $px)
    let hi = ($px | math max)
    let lo = ($px | math min)
    let last = ($px | last)
    {
      symbol: $e.sym
      name: $e.name
      close: (r4 $last)
      ret_1d: (r4 (ret-n $px 1))
      ret_5d: (r4 (ret-n $px 5))
      ret_20d: (r4 (ret-n $px 20))
      ret_60d: (r4 (ret-n $px 60))
      vol_ann: (r4 (series volatility $px --from prices --method log | get value))
      max_drawdown: (r4 ($dd | get max))
      drawdown_now: (r4 ($dd | get current))
      high_130d: (r4 $hi)
      low_130d: (r4 $lo)
      pos_in_130d: (r4 (($last - $lo) / ($hi - $lo)))
      window: $"($h | first | get reference_period) -> ($h | last | get reference_period)"
    }
  }
}

# 注：nushell 里 def 内部非末尾的管道结果不会显示，要看得显式 print
def main [--dry-run, --out: string = "digest.json"] {
  print "== 1/3 取数（market）+ 本地计算（series）=="
  let curve = (get-curve)
  let eq = (get-equities)
  let fx = (market fx --base USD --to "CNY,EUR,JPY" | each {|r| {pair: $r.series value: $r.value as_of: $r.reference_period} })
  let as_of = ($curve | first | get as_of)
  let lv = {|t| $curve | where tenor == $t | get 0.latest }
  let digest = {
    as_of: $as_of
    note: "the ust curve carries the treasury data date; the equity window ends at the latest session, so the two can differ by a day. every position is within the window shown, not multi-year history."
    us_treasury_curve: $curve
    curve_spreads_pp: {
      "10y_minus_2y": (r4 ((do $lv "10 Yr") - (do $lv "2 Yr")))
      "10y_minus_3m": (r4 ((do $lv "10 Yr") - (do $lv "3 Mo")))
      "30y_minus_5y": (r4 ((do $lv "30 Yr") - (do $lv "5 Yr")))
    }
    fx_ecb_fixing: $fx
    equities_130d: $eq
  }
  $digest | to json -r | save --force $out
  print $"   曲线 as_of ($as_of)；权益窗口 ($eq | first | get window)；已写 ($out)"

  print "\n== 2/3 事实清单 =="
  $curve | each {|c| {tenor: $c.tenor latest: $c.latest chg: $c.change pctile: ($c.percentile | math round --precision 3) z: ($c.zscore | math round --precision 2)}} | table -e | to text | print
  $digest.curve_spreads_pp | to md -p | print
  $fx | table -e | to text | print
  $eq | select symbol close ret_1d ret_20d ret_60d vol_ann max_drawdown pos_in_130d | table -e | to text | print

  if $dry_run { print "\n== [dry-run] 跳过 agent =="; return }

  print "\n== 3/3 交给 agent（可自行再调 market 取数）=="
  let sys = "你是跨资产策略分析师。只依据给定数据下判断：数据支持的才说，不支持的明说不知道。不要复述输入，直接给结论，每个判断都带上支撑它的数字。"
  let ask = $"以下是 ($as_of) 的市场数据，由一段 nushell 脚本取数并用 series 本地算出，未经人工调整：`n`n($digest | to json -r)`n`n请分析近期市场情况：`n1. 一句话总览：现在是什么状态。`n2. 三条最值得注意的事实，每条引用具体数字和它在自身历史中的位置。`n3. 跨资产一致性：美债、人民币、A股之间是互相印证还是彼此矛盾？矛盾在哪。`n4. 只能盯三个指标的话选哪三个，各给一个触发阈值，越过它意味着什么。`n5. 这份数据最明显的缺口是什么——哪一类判断因为缺数据而不能下。`n`n需要更多数据时可以调用 market 工具自己取（其他期限、别的标的、盘中分钟线）。"
  let out = (try {
    agent $ask --system $sys --tools-from [market] --max-rounds 6 --tool-timeout 60sec --no-save
  } catch {|e|
    print $"[tools-from 不可用：($e.msg)] 退回无工具模式"
    agent $ask --system $sys --no-save
  })
  print $out
}
