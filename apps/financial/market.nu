# market.nu — the market data layer: prices, rates and curves
#
#   use market.nu
#
#   market sources
#   market curve --limit 5                # the US Treasury yield curve (every tenor)
#   market history sh000001 --limit 250   # daily OHLCV for an A-share index or stock
#   market quote sh000001                 # the current session's snapshot
#   market quote fx_susdcnh               # offshore renminbi, USD/CNH
#   market fx --to CNY                    # ECB reference rates
#
# every one of these takes `--as records|frame|state`, exactly as the macro sources do, so
# a single call can answer "what is it, and where does it sit" without a pipeline — see the
# note on `view` below for why that matters.
#
# all four sources are keyless. Yahoo and Stooq were tried first and are not here: Yahoo
# answers 403 without a crumb, and Stooq served an HTML interstitial in place of its CSV.

use ./market-parse.nu
use ./cache.nu
use ./macro.nu

const TREASURY_CSV = "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv"
const SINA_KLINE = "https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketData.getKLineData"
const SINA_MINUTE = "https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData"
const SINA_HQ = "https://hq.sinajs.cn/list="
const FRANKFURTER = "https://api.frankfurter.app/latest"

# the Chinese sources refuse a request with no Referer, and a browser-ish User-Agent
const SINA_HEADERS = {User-Agent: "Mozilla/5.0", Referer: "https://finance.sina.com.cn"}

# the sources, and what each can honestly answer
export def sources []: nothing -> table {
  [
    {source: "treasury-curve" needs: "" market: "US Treasuries"  note: "the daily yield curve, every published tenor from 1 month to 30 years"}
    {source: "sina-kline"     needs: "" market: "A-shares, HK"   note: "daily OHLCV history; symbols like sh000001, sz399001, hkHSI"}
    {source: "sina-quote"     needs: "" market: "A-shares, FX"   note: "a live snapshot during the session; fx_susdcnh is offshore renminbi"}
    {source: "frankfurter"    needs: "" market: "FX"             note: "ECB reference fixings, one per business day"}
  ]
}

# a payload that may or may not have been parsed already. nu parses a body when the source
# declares a JSON content type and hands back a string otherwise, and the same URL can go
# either way depending on the cache — so the type is what decides, not an assumption.
def as-json [x: any]: nothing -> any {
  if (($x | describe) | str starts-with "string") { $x | from json } else { $x }
}

# the three views of a fetched series. same contract as macro.nu's, and the same reason: a
# tool call cannot carry a pipeline, so an agent asked to compose `fetch | frame | state`
# would have to echo every observation back as an argument.
#
# the guard matters as much as the views. a frame is ONE series, and several of these
# sources return several at once — every tenor of the curve, or all of OHLCV. putting a
# ten-year yield and a two-year yield on one axis produces a number that looks like an
# answer and is not, so it is refused, with the filter that fixes it named in the message.
def view [records: list<record>, as: string]: nothing -> any {
  if $as == "records" { return $records }
  let series = ($records | get series | uniq)
  if ($series | length) > 1 {
    error make { msg: $"these records span ($series | length) series, starting ($series | first 3 | str join ', ') — a ($as) is one series. filter first: `--tenor \"10 Yr\"` for the curve, or `--fields close` for history" }
  }
  if $as == "frame" {
    macro frame $records
  } else if $as == "state" {
    macro state $records
  } else {
    error make { msg: $"unknown --as '($as)': use records, frame or state" }
  }
}

# ── commands ──

# the US Treasury yield curve. one record per (date, tenor), so `state` on "UST:10 Yr" is
# the ten-year's level and where it sits in its own recent history.
export def curve [
  --year: int              # which vintage; defaults to the current year
  --tenor: string          # filter to one, e.g. "10 Yr" — required for --as frame/state
  --as: string = "records" # records | frame | state
]: nothing -> any {
  let y = ($year | default ((date now | format date "%Y") | into int))
  let url = $"($TREASURY_CSV)/($y)/all?type=daily_treasury_yield_curve&field_tdr_date_value=($y)&page&_format=csv"
  let all = (market-parse treasury-curve (as-json (cache fetch $url --source treasury-curve).payload) $url)
  let picked = (if $tenor == null { $all } else { $all | where series == $"UST:($tenor)" })
  if $tenor != null and ($picked | is-empty) {
    error make { msg: $"no tenor '($tenor)'. available: (($all | get series | uniq) | str join ', ')" }
  }
  view $picked $as
}

# daily history for a symbol. `--fields` selects which series to emit, because OHLCV is five
# series and a frame is one.
export def history [
  symbol: string           # sh000001, sz399001, sh600519, …
  --limit: int = 250       # trading days back
  --fields: string = "close"   # comma-separated: close, open, high, low, volume
  --as: string = "records" # records | frame | state
]: nothing -> any {
  let want = ($fields | split row "," | each {|f| $f | str trim } | where {|f| $f | is-not-empty })
  let url = $"($SINA_KLINE)?symbol=($symbol)&scale=240&datalen=($limit)"
  let payload = (as-json ((cache fetch $url --source sina-kline --header $SINA_HEADERS).payload))
  view (market-parse sina-kline $payload $symbol $url $want) $as
}

# intraday bars. the same endpoint as `history` with a minute scale, so the same parser: the
# rows carry `day` as a full timestamp and the same OHLCV columns. this is the granularity
# 底仓+T+0 needs — a daily bar contains no path inside the session, and the T+0 pattern lives
# entirely inside one.
export def intraday [
  symbol: string           # sh000001, sh600519, …
  --scale: int = 5         # minutes per bar: 1, 5, 15, 30 or 60
  --limit: int = 240       # bars back
  --fields: string = "close"
  --as: string = "records"
]: nothing -> any {
  let want = ($fields | split row "," | each {|f| $f | str trim } | where {|f| $f | is-not-empty })
  let url = $"($SINA_MINUTE)?symbol=($symbol)&scale=($scale)&ma=no&datalen=($limit)"
  let payload = (as-json ((cache fetch $url --source sina-kline --header $SINA_HEADERS).payload))
  view (market-parse sina-kline $payload $symbol $"($url)" $want) $as
}

# the current session's snapshot. cached for five minutes, because a live price is wrong the
# moment the market moves.
export def quote [
  symbol: string           # sh000001, fx_susdcnh, …
  --as: string = "records"
]: nothing -> any {
  let url = $"($SINA_HQ)($symbol)"
  let body = ((cache fetch $url --source sina-quote --header $SINA_HEADERS --decode gbk).payload)
  view (market-parse sina-quote $body $symbol $url) $as
}

# ECB reference fixings — the onshore side of a currency pair, published once a day
export def fx [
  --base: string = "USD"
  --to: string = "CNY"     # comma-separate for several, e.g. --to "CNY,JPY,EUR"
  --as: string = "records"
]: nothing -> any {
  let url = $"($FRANKFURTER)?from=($base)&to=($to)"
  view (market-parse frankfurter (as-json (cache fetch $url --source frankfurter).payload) $url) $as
}
