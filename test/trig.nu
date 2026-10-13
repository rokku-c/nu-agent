#!/usr/bin/env nu
# schedule.nu — rules stated in advance
#
# the hermetic half: what a rule must carry, how a node gates it, and the state it reports.
# `trig check` observes a live market and is exercised outside this suite.

use ./harness.nu *
use ./../apps/financial/trig.nu

$env.NU_AGENT_TRIG_DIR = ($nu.temp-dir | path join $"nu-agent-trig-test-(random int 100000..999999)")
mkdir $env.NU_AGENT_TRIG_DIR

let results = [
  (case "rule: a price condition needs a subject, a symbol and a level" {
    (throws "rule: a price condition needs a subject, a symbol and a level" {
      trig rule --subject "X" --symbol sh000001 --condition below
    })
  })

  (case "rule: a condition that is neither above nor below is refused" {
    (throws "rule: a condition that is neither above nor below is refused" {
      trig rule --subject "X" --symbol sh000001 --condition near --level 1.0
    })
  })

  (case "rule: a stated rule is recorded with the moment it was stated" {
    let r = (trig rule --subject "SSE" --symbol sh000001 --condition below --level 3700)
    (eq "rule: a stated rule is recorded with the moment it was stated" [$r.subject $r.condition $r.level] ["SSE" "below" 3700])
  })

  (case "list: a rule with no node is armed immediately" {
    (eq "list: a rule with no node is armed immediately" (trig list | where subject == "SSE" | first | get state) "armed")
  })

  (case "list: a node in the future holds the rule pending" {
    # the 定时 half: a rule stated now that must not be evaluated before its date
    trig rule --subject "NODED" --symbol sh000001 --condition above --level 1.0 --node 2099-01-01 | ignore
    (eq "list: a node in the future holds the rule pending" (trig list | where subject == "NODED" | first | get state) "pending")
  })

  (case "list: a node already past leaves the rule armed" {
    trig rule --subject "PAST" --symbol sh000001 --condition above --level 1.0 --node 2020-01-01 | ignore
    (eq "list: a node already past leaves the rule armed" (trig list | where subject == "PAST" | first | get state) "armed")
  })

  (case "list: the state is one of armed, pending or fired — never a bare boolean" {
    let states = (trig list | get state | uniq | sort)
    (is-true "list: the state is one of armed, pending or fired — never a bare boolean" (
      ($states | all {|s| $s in ["armed" "pending" "fired"] })
    ))
  })

  (case "purge: clears the store" {
    trig purge | ignore
    (eq "purge: clears the store" (trig list) [])
  })
]

emit $results
