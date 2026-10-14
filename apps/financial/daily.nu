# daily.nu — the daily node: one command that runs the whole routine and archives it
#
#   use daily.nu
#
#   daily watch                                  # what the node looks at
#   daily node                                   # run it now, archive the result
#   daily archive                                # every run ever made, newest first
#   daily show                                   # the most recent run
#
# ── why this exists ──
# the modules each answer a question; none of them is a routine. this is the routine, and it
# is deliberately thin: read the watchlist, check the triggers, list what is due, and write
# the whole thing down. every step it calls already exists and is tested.
#
# ── the run is archived, and that is the point ──
# a run is a dated record of what the system saw and what it said on that date. without it
# there is no way to ask "what did this look like last Tuesday", and without THAT there is no
# way to tell whether anything here works. a node that leaves no trace is a habit, not a
# system.
#
# a second run on the same day is a NEW record, not an overwrite: a morning reading and a
# close reading are two different observations, and the difference between them is
# information. `daily show` gives the latest for the day; `daily archive` gives them all.
#
# ── one source failing does not fail the node ──
# a daily routine that dies because one website was slow is a routine you stop trusting. each
# reading is taken in isolation and a failure is recorded as a failure — a hole in the record
# is a fact about that day, and hiding it would make the archive lie.

use ./macro.nu
use ../../core/reason.nu
use ./market.nu
use ./trig.nu
use ./pred.nu

const DIR_NAME = "nu-agent-daily"

def today []: nothing -> string { date now | format date "%Y-%m-%d" }

def store-dir []: nothing -> path {
  let override = ($env.NU_AGENT_DAILY_DIR? | default "")
  if ($override | is-empty) { $nu.data-dir | path join $DIR_NAME } else { $override | path expand }
}

def watch-path []: nothing -> path { store-dir | path join "watchlist.json" }

# the default watchlist: the series this checkout can actually reach with no key. it is a
# file rather than a constant so the routine can be pointed at a different set without
# editing code.
def default-watchlist []: nothing -> list<record> {
  [
    {label: "US 10Y",        kind: "curve",   tenor: "10 Yr"}
    {label: "US 2Y",         kind: "curve",   tenor: "2 Yr"}
    {label: "US policy rate", kind: "nyfed",  limit: 250}
    {label: "EU inflation",  kind: "eurostat", dataset: "prc_hicp_manr", params: {geo: EA, coicop: CP00}, limit: 120}
    {label: "SSE",           kind: "history", symbol: "sh000001", limit: 250}
    {label: "USD/CNH",       kind: "quote",   symbol: "fx_susdcnh"}
  ]
}

def watchlist []: nothing -> list<record> {
  let p = (watch-path)
  if ($p | path exists) { open $p } else { default-watchlist }
}

# one reading, as a state where there is a history and as a bare latest where there is not.
# a live quote has exactly one observation, so it has no position to report — and saying so
# is better than inventing one.
def reading [w: record]: nothing -> record {
  let state = (
    if $w.kind == "curve" {
      market curve --tenor $w.tenor --as state
    } else if $w.kind == "history" {
      market history $w.symbol --limit $w.limit --as state
    } else if $w.kind == "quote" {
      let r = (market quote $w.symbol | where {|x| $x.series == $"($w.symbol):close" or $x.series == $w.symbol } | last)
      {series: $r.series, as_of: $r.reference_period, latest: $r.value, units: $r.units,
       percentile: null, zscore: null, change: null, observations: 1, note: "a live snapshot: one observation, so there is no position within a history to report"}
    } else if $w.kind == "nyfed" {
      macro nyfed --limit $w.limit --as state
    } else if $w.kind == "eurostat" {
      macro eurostat $w.dataset --params $w.params --limit $w.limit --as state
    } else {
      error make { msg: $"unknown watchlist kind '($w.kind)'" }
    }
  )
  {
    label: $w.label
    series: $state.series
    as_of: $state.as_of
    latest: $state.latest
    change: ($state | get --optional change)
    percentile: ($state | get --optional percentile)
    zscore: ($state | get --optional zscore)
    observations: ($state | get --optional observations)
  }
}

# ── commands ──

# show the watchlist, or replace it
export def watch [
  --set: list<record>      # replace the watchlist with this
]: nothing -> any {
  if $set == null { return (watchlist) }
  mkdir (store-dir)
  $set | save -f (watch-path)
  $set
}

# run the node: read the watchlist, check the triggers, list what is due, archive the lot
export def node [
  --date: string           # label the run with this date instead of today
  --dry-run                # do everything but write the archive record
]: nothing -> record {
  let day = ($date | default (today))
  let started = (date now | format date "%Y-%m-%dT%H:%M:%S")

  # each reading stands alone: one unreachable source leaves a hole, not a dead node
  let readings = (
    watchlist | each {|w|
      try {
        reading $w
      } catch {|e|
        {label: $w.label, series: null, as_of: null, latest: null, change: null,
         percentile: null, zscore: null, observations: null, error: ((reason $e) | str substring 0..200)}
      }
    }
  )

  # the triggers and the prediction queue are the two halves of "what needs attention today"
  let triggers = (try { trig check } catch {|e| [{state: "unknown", because: ((reason $e) | str substring 0..200)}] })
  let due = (try { pred due } catch {|e| [] })

  let record = {
    date: $day
    ran_at: $started
    readings: $readings
    triggers: $triggers
    predictions_due: $due
    failures: ($readings | where {|r| ($r | get --optional error) != null } | get label)
  }

  if not $dry_run {
    mkdir (store-dir)
    # a second-resolution stamp alone is not unique: two runs inside the same second
    # overwrote each other, and the archive silently lost one — measured, on the first
    # attempt at running this twice in a row. the suffix is what makes "every run is kept"
    # true rather than aspirational.
    let stamp = (date now | format date "%H%M%S")
    let uniq = (random int 1000..9999)
    $record | save -f (store-dir | path join $"($day)-($stamp)-($uniq).json")
  }
  $record
}

# every run ever made, newest first — the index
export def archive []: nothing -> any {
  let dir = (store-dir)
  if not ($dir | path exists) { return [] }
  glob ($dir | path join "*.json")
  | where {|p| ($p | path parse | get stem) != "watchlist" }
  | each {|p|
      let r = (try { open $p } catch { null })
      if $r == null { null } else {
        {
          date: $r.date
          ran_at: $r.ran_at
          readings: ($r.readings | length)
          failures: ($r.failures | length)
          triggers_fired: ($r.triggers | where state == "fired" | length)
          predictions_due: ($r.predictions_due | length)
        }
      }
    }
  | compact
  | sort-by ran_at --reverse
}

# the most recent run, or the most recent one for a given date
export def show [
  --date: string
]: nothing -> any {
  let dir = (store-dir)
  if not ($dir | path exists) { error make { msg: "no runs archived yet — `daily node` writes one" } }
  let files = (
    glob ($dir | path join "*.json")
    | where {|p| ($p | path parse | get stem) != "watchlist" }
    | where {|p| $date == null or (($p | path parse | get stem) | str starts-with $date) }
    | sort
  )
  if ($files | is-empty) { error make { msg: "no run archived for that date" } }
  open ($files | last)
}

# ── the browser view ──
#
# renders the most recent run as ONE self-contained HTML file: no server, no CDN, no fetch,
# nothing to install. it follows the precedent core/trace.nu set for run traces — nushell
# builds the page and the browser only reads it.
#
# that split is forced, not chosen. nu-agent executes a tool by forking `nu --config …`, and
# a browser has no processes to fork; and none of these sources send CORS headers, so a page
# fetching them directly is blocked. the data work stays local; the browser gets a file.
export def report [
  --out: path = "daily.html"   # where to write it
  --open                       # open it in the default browser afterwards
  --date: string               # a specific run instead of the most recent
]: nothing -> string {
  let r = (show --date $date)

  let pct = {|p|
    if $p == null { "" } else { $"<div class=bar><span style=\"width:($p * 100 | math round)%\"></span></div>" }
  }
  let num = {|v, digits|
    if $v == null { "—" } else { ($v | math round --precision $digits) | into string }
  }

  let rows = (
    $r.readings | each {|x|
      let bad = (($x | get --optional error) != null)
      $"<tr class=(if $bad { 'bad' } else { '' })>
        <td class=lbl>($x.label)</td>
        <td class=num>(if $bad { '—' } else { do $num $x.latest 4 })</td>
        <td class=dim>($x.as_of | default '—')</td>
        <td class=dim>(if $bad { '—' } else { do $num $x.change 4 })</td>
        <td class=num>(if $bad { '—' } else { do $num $x.percentile 3 })</td>
        <td class=bar-cell>(if $bad { '' } else { do $pct $x.percentile })</td>
        <td class=dim>(if $bad { ($x.error | str substring 0..60) } else { do $num $x.observations 0 })</td>
      </tr>"
    } | str join (char nl)
  )

  let trig_rows = (
    if ($r.triggers | is-empty) { "<tr><td colspan=3 class=dim>none armed</td></tr>" } else {
      $r.triggers | each {|t| $"<tr><td>($t.subject | default '—')</td><td class=st-($t.state)>($t.state)</td><td class=dim>($t.because | default '—')</td></tr>" } | str join (char nl)
    }
  )

  let due_rows = (
    if ($r.predictions_due | is-empty) { "<tr><td colspan=4 class=dim>nothing due</td></tr>" } else {
      $r.predictions_due | each {|d| $"<tr><td>($d.subject)</td><td>($d.direction | default '—')</td><td class=num>($d.at)</td><td class=dim>($d.horizon)</td></tr>" } | str join (char nl)
    }
  )

  # the CSS never interpolates, so it is single-quoted: inside $"..." a literal `(` opens an
  # interpolation, and a stylesheet is full of them — measured, it tried to run
  # `prefers-color-scheme:light` as a command.
  let css = '<style>
  :root{--bg:#0f1115;--fg:#e6e8ee;--dim:#8b93a7;--line:#242938;--accent:#5b9cf8;--bad:#f2555a;--ok:#3fb950;--warn:#d29922}
  @media (prefers-color-scheme:light){:root{--bg:#fbfbfd;--fg:#1b1f2a;--dim:#6b7280;--line:#e5e7eb;--accent:#2563eb}}
  *{box-sizing:border-box}
  body{margin:0;padding:32px 20px 64px;background:var(--bg);color:var(--fg);
       font:15px/1.5 ui-sans-serif,-apple-system,''Segoe UI'',system-ui,sans-serif}
  .wrap{max-width:920px;margin:0 auto}
  h1{font-size:20px;margin:0 0 4px;font-weight:600}
  h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);
     margin:32px 0 10px;font-weight:600}
  .sub{color:var(--dim);font-size:13px;margin-bottom:8px}
  table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
  th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:.06em;
     color:var(--dim);font-weight:600;padding:6px 8px;border-bottom:1px solid var(--line)}
  td{padding:7px 8px;border-bottom:1px solid var(--line)}
  tr.bad td{color:var(--bad)}
  .lbl{font-weight:500}
  .num{text-align:right}
  .dim{color:var(--dim)}
  .bar-cell{width:130px}
  .bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden}
  .bar span{display:block;height:100%;background:var(--accent)}
  .st-fired{color:var(--ok);font-weight:600}
  .st-armed{color:var(--dim)}
  .st-unknown,.st-pending{color:var(--warn)}
  footer{margin-top:40px;color:var(--dim);font-size:12px;border-top:1px solid var(--line);padding-top:14px}
  code{background:var(--line);padding:1px 5px;border-radius:4px;font-size:12px}
</style>'

  let html = $"<!doctype html>
<html lang=en><head><meta charset=utf-8>
<meta name=viewport content=\"width=device-width,initial-scale=1\">
<title>nu-agent · ($r.date)</title>
${css}</head><body><div class=wrap>
<h1>nu-agent · 宏观与市场</h1>
<div class=sub>($r.date) · run ($r.ran_at) · ($r.readings | length) readings · ($r.failures | length) failed</div>

<h2>读数</h2>
<table><thead><tr><th>series</th><th class=num>latest</th><th>as of</th><th class=num>change</th>
<th class=num>pct</th><th></th><th class=num>n</th></tr></thead><tbody>
($rows)
</tbody></table>

<h2>触发规则</h2>
<table><thead><tr><th>subject</th><th>state</th><th>why</th></tr></thead><tbody>
($trig_rows)
</tbody></table>

<h2>该对账的预测</h2>
<table><thead><tr><th>subject</th><th>direction</th><th class=num>at</th><th>horizon</th></tr></thead><tbody>
($due_rows)
</tbody></table>

<footer>
  <code>pct</code> 是它在自身历史中的分位 —— 数值本身没有意义,位置才有。<br>
  每个数字都来自内核,并带着它的口径;失败的读数留空,不填零。<br>
  由 <code>daily report</code> 生成 —— 自包含,无外部请求。
</footer>
</div></body></html>"

  $html | save -f $out
  if $open { ^open $out }
  $out | path expand | into string
}
