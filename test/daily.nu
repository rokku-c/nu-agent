#!/usr/bin/env nu
# daily.nu — the node's archive discipline
#
# the archive half is hermetic (it is files). `daily node` reads live markets and is exercised
# outside this suite; --dry-run is tested here because the writing is exactly what must not
# happen silently.

use ./harness.nu *
use ./../apps/financial/daily.nu

$env.NU_AGENT_DAILY_DIR = ($nu.temp-dir | path join $"nu-agent-daily-test-(random int 100000..999999)")
mkdir $env.NU_AGENT_DAILY_DIR

let results = [
  (case "watch: the default watchlist is the series this checkout can actually reach" {
    let w = (daily watch)
    (is-true "watch: the default watchlist is the series this checkout can actually reach" ((($w | length) >= 5) and ($w | all {|x| ($x.label | is-not-empty) })))
  })

  (case "watch: --set replaces it and it persists" {
    daily watch --set [{label: "ONLY", kind: "quote", symbol: "fx_susdcnh"}] | ignore
    let labels = (daily watch | get label)
    # drop the override so the later cases see the default again
    rm -f ($env.NU_AGENT_DAILY_DIR | path join "watchlist.json")
    (eq "watch: --set replaces it and it persists" $labels ["ONLY"])
  })

  (case "archive: an empty archive is a list, not an error" {
    (eq "archive: an empty archive is a list, not an error" (daily archive) [])
  })

  (case "show: asking for a run when none exists says so instead of returning null" {
    (throws "show: asking for a run when none exists says so instead of returning null" { daily show })
  })

  (case "node: --dry-run does everything and writes nothing" {
    # the writing is precisely what must not happen silently: a routine that archived when
    # you asked it not to would fill the store with runs nobody made
    let r = (daily node --dry-run)
    (is-true "node: --dry-run does everything and writes nothing" (
      (($r | get --optional ran_at) != null) and ((daily archive | length) == 0)
    ))
  })

  (case "node: a failing reading is recorded as a failure, not as a dead node" {
    # one unreachable source must leave a hole, not kill the routine — a hole in the record
    # is a fact about that day, and hiding it would make the archive lie
    daily watch --set [
      {label: "GOOD", kind: "quote", symbol: "fx_susdcnh"}
      {label: "BAD", kind: "quote", symbol: "fx_no_such_pair"}
    ] | ignore
    let r = (daily node --dry-run)
    let got = [($r.readings | length) ($r.failures)]
    rm -f ($env.NU_AGENT_DAILY_DIR | path join "watchlist.json")
    (eq "node: a failing reading is recorded as a failure, not as a dead node" $got [2 ["BAD"]])
  })
]

emit $results
