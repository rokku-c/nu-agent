# filings.nu — company financials from SEC EDGAR, with their filing dates intact
#
#   use filings.nu
#
#   filings cik AAPL                                   # ticker -> CIK (SEC's own namespace)
#   filings concepts 320193 --limit 10                 # what this company reports
#   filings concept 320193 Revenues --annual --limit 5
#   filings concept 320193 Revenues --as-of 2024-03-01 # what was KNOWN on that date
#
# ── why EDGAR, and why this is the first source here with a real vintage ──
# EDGAR is official, keyless, and structured: companies file XBRL, and every fact carries the
# date it was FILED beside the period it describes. that pairing is a vintage, which means
# two things this module exists to make usable:
#
#   · "what did they report for FY2023 as of March 2024" is answerable — `--as-of` cuts to
#     the vintages that were public then, not to whatever the number says today.
#   · a RESTATEMENT is visible rather than silent. the same period with two different values
#     and two different filing dates is information; a system that keeps only the latest
#     value has thrown that information away, and it is exactly the information you needed
#     if you acted on the first one.
#
# this is the same discipline as the macro layer's `--as-of`, arriving from a different
# direction: there the point was not to revise your own history, here it is not to let the
# company revise yours.
#
# ── one caveat that is not a detail ──
# XBRL tag names are not stable across companies or years: `Revenues` on one filer is
# `RevenueFromContractWithCustomerExcludingAssessedTax` on another. the module will not guess
# a mapping — run `filings concepts` and name the tag you mean.

use ./filings-parse.nu
use ./cache.nu

const TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"

# the SEC requires a descriptive User-Agent identifying the caller, and answers a bare one
# with a block. the contact is a placeholder: put a real one here before relying on this, or
# the block will arrive one day without warning.
def sec-headers []: nothing -> record {
  {User-Agent: ($env.NU_AGENT_SEC_UA? | default "nu-agent research contact@example.com")}
}

def cik-pad [cik: string]: nothing -> string {
  # EDGAR paths want the CIK zero-padded to ten digits. written out rather than computed:
  # the arithmetic version silently produced a wrong width the first time, and a wrong CIK
  # returns a 404 that reads like "this company has no filings".
  let c = ($cik | into string | str replace -r '^0+' '')
  match ($c | str length) {
    1 => $"000000000($c)"
    2 => $"00000000($c)"
    3 => $"0000000($c)"
    4 => $"000000($c)"
    5 => $"00000($c)"
    6 => $"0000($c)"
    7 => $"000($c)"
    8 => $"00($c)"
    9 => $"0($c)"
    _ => $c
  }
}

# ── commands ──

# the SEC's ticker → CIK bridge. the two namespaces are unrelated; this is the only map.
export def cik [ticker: string]: nothing -> record {
  let r = (cache fetch $TICKERS_URL --source edgar --header (sec-headers) --ttl 7day)
  let c = (filings-parse edgar-cik $r.payload $ticker)
  {ticker: ($ticker | str uppercase), cik: $c, padded: (cik-pad $c)}
}

# the tags this company reports, with how many facts each carries
export def concepts [
  cik: string
  --limit: int = 25
]: nothing -> table {
  let url = $"https://data.sec.gov/api/xbrl/companyfacts/CIK(cik-pad $cik).json"
  let r = (cache fetch $url --source edgar --header (sec-headers) --ttl 24hr)
  filings-parse edgar-taxonomy $r.payload | sort-by facts --reverse | first $limit
}

# one tagged figure over time, every vintage of it
export def concept [
  cik: string
  tag: string              # an XBRL tag, e.g. Revenues — run `filings concepts` for the list
  --annual                 # keep only periods of roughly a year
  --as-of: string          # show what was KNOWN on this date, not what it says now
  --limit: int = 20
  --all-vintages           # keep every vintage instead of the latest per period
]: nothing -> any {
  let url = $"https://data.sec.gov/api/xbrl/companyconcept/CIK(cik-pad $cik)/us-gaap/($tag).json"
  let r = (cache fetch $url --source edgar --header (sec-headers) --ttl 24hr)
  if (($r.payload | describe) | str starts-with "string") {
    error make { msg: $"no us-gaap tag '($tag)' for CIK ($cik). run `filings concepts ($cik)` for the tags this filer uses" }
  }
  let all = (filings-parse edgar $r.payload $tag $url)
  let filtered = (
    if $annual {
      # XBRL carries quarterly and annual facts under one tag; a roughly-365-day span is the
      # annual one, and the window is loose because a 52/53-week filer is normal
      # the span in DAYS, not nanoseconds: the first version compared a nanosecond duration
      # against a threshold three orders of magnitude too small, which would have kept every
      # quarterly fact and quietly turned "annual" into "everything"
      # note: `and` must stay on the same line as its left operand — starting a line with it
      # makes nushell parse it as an external command (the same trap expose.nu documents)
      $all | where {|x| ($x.period_start != null) and ((((($x.reference_period | into datetime) - ($x.period_start | into datetime)) | into int) / 86_400_000_000_000) > 300) }
    } else { $all }
  )
  let cut = (filings-parse as-of $filtered $as_of)
  let out = (if $all_vintages or $as_of != null { $cut } else { filings-parse as-of $cut null | sort-by reference_period | last $limit })
  $out | sort-by reference_period | select reference_period value vintage units form | last $limit
}
