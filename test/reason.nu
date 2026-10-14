#!/usr/bin/env nu
# reason.nu — error-unwrapping regression tests
#
# these exist because the unwrap is the one thing standing between a real failure and a
# sentence that names nothing, and the version that looked right was wrong. the trap:
#
#   reading `.details.inner` ONCE looks like it handles the wrapper. it handles ONE level of
#   it. each nesting level adds another, and only the first hangs off `details` — every level
#   below hangs off `inner`. so with `each` inside `each` the one-level walk returns the
#   wrapper verbatim, and the reader is exactly where they started.
#
# that is not a corner: the agent loop nests closures, so the failures that reach a person are
# the deep ones. the two-level and three-level cases below are the regression.

use ./harness.nu *
use ../core/reason.nu
# the last case below drives the real `agent`, so the module has to be in scope. without this
# line `agent` is not a command, nu falls through to the external-command path, and the call dies
# on its own list argument ("Lists are not automatically spread when calling external commands")
# BEFORE anything under test runs — a green-looking test that had never once reached the code it
# names. found 2026-10-13 while validating an unrelated change; it is why the case read as passing
# in one run and failing in the next.
use ../core/agent.nu

let results = [
  (case "reason: an unwrapped error is returned as-is" {
    let e = (try { error make {msg: "plain failure"} } catch {|err| $err })
    (eq "reason: an unwrapped error is returned as-is" (reason $e) "plain failure")
  })

  (case "reason: one closure deep" {
    let e = (try { [1] | each {|x| error make {msg: "ONE LEVEL"} } } catch {|err| $err })
    (eq "reason: one closure deep" (reason $e) "ONE LEVEL")
  })

  (case "reason: two closures deep — the regression" {
    let e = (try { [1] | each {|a| [2] | each {|b| error make {msg: "TWO LEVELS"} } } } catch {|err| $err })
    (eq "reason: two closures deep — the regression" (reason $e) "TWO LEVELS")
  })

  (case "reason: three closures deep" {
    let e = (try {
      [1] | each {|a| [2] | each {|b| [3] | each {|c| error make {msg: "THREE LEVELS"} } } }
    } catch {|err| $err })
    (eq "reason: three closures deep" (reason $e) "THREE LEVELS")
  })

  (case "reason: a where closure counts the same way" {
    let e = (try { [1] | where {|x| error make {msg: "IN WHERE"} } } catch {|err| $err })
    (eq "reason: a where closure counts the same way" (reason $e) "IN WHERE")
  })

  (case "reason: a do block counts the same way" {
    let e = (try { do { error make {msg: "IN DO"} } } catch {|err| $err })
    (eq "reason: a do block counts the same way" (reason $e) "IN DO")
  })

  (case "reason: a NATIVE error from inside a closure is unwrapped too (not just error make)" {
    # the wrapper is not reserved for `error make`. an external command failing, a division by
    # zero, a failed conversion — anything raised inside a closure comes out wrapped, and its
    # inner row carries the real message.
    let e = (try { [1] | each {|x| ^false } } catch {|err| $err })
    (has "reason: a NATIVE error from inside a closure is unwrapped too (not just error make)" (reason $e) "non-zero exit code")
  })

  (case "reason: not a record is not a crash" {
    # an `inner` entry is typed list<any>, so a bare string can turn up where a record is
    # expected — and `get --optional` on a string RAISES rather than returning null
    (eq "reason: not a record is not a crash" (reason "just a string") "just a string")
  })

  (case "reason: falls back to nu's rendered form when the chain is empty" {
    # unreachable in practice so far, but it is the branch that keeps "names nothing" from
    # ever being the answer. built by hand: a wrapper whose `inner` is empty.
    let e = {
      msg: "Eval block failed with pipeline input"
      details: {msg: "Eval block failed with pipeline input", inner: []}
      rendered: "Error: nu::shell::eval_block_with_input\n\n  x Eval block failed with pipeline input\n   ,-[x:1:1]\n\nError: \n  x SCRAPED FROM RENDERED\n   ,-[x:1:2]\n"
    }
    (eq "reason: falls back to nu's rendered form when the chain is empty" (reason $e) "SCRAPED FROM RENDERED")
  })

  (case "reason: the chain drops the repeated wrapper" {
    let e = (try { [1] | each {|a| [2] | each {|b| error make {msg: "TWO LEVELS"} } } } catch {|err| $err })
    (eq "reason: the chain drops the repeated wrapper" (reason chain $e) ["Eval block failed with pipeline input" "TWO LEVELS"])
  })

  (case "reason: a missing --tools-from module is NAMED, not swallowed" {
    # the end-to-end shape of the original report: "agent 出错: Eval block failed with pipeline
    # input" for a tool list that named a module the config had not `use`d. resolution happens
    # before the first API call, so this costs nothing and needs no credentials.
    let raised = (try {
      agent "hi" --tools-from [no-such-module]
      "no error"
    } catch {|err| reason $err })
    (has "reason: a missing --tools-from module is NAMED, not swallowed" $raised "no-such-module")
  })
]

emit $results
