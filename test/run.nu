#!/usr/bin/env nu
# run.nu — the test runner
#
#   nu test/run.nu              # everything
#   nu test/run.nu unit mcp     # only the named suites
#
# each suite is a separate `nu` process with its own config, so a suite that
# hangs or dies cannot take the others with it. suites report ✓/✗ on stderr and
# their results as JSON on stdout; this aggregates the JSON.
#
# exit code is non-zero when anything failed, so it drops straight into CI.

# suite name -> what it covers. order is deliberate: cheap and hermetic first.
const SUITES = [
  {name: "unit",    covers: "pure functions, no network"}
  {name: "resolve", covers: "module resolution + the naming contract"}
  {name: "openai",  covers: "the OpenAI dialect's translation and stream state"}
  {name: "stream",  covers: "the SSE state machine, replayed from canned bytes"}
  {name: "policy",  covers: "the tool permission gate"}
  {name: "session", covers: "persistence, resume and the unfolded-history invariant"}
  {name: "task",    covers: "subagent orchestration, depth and capability guards"}
  {name: "mcp",     covers: "the MCP server over real stdio"}
  {name: "e2e",     covers: "a real model endpoint (needs credentials)"}
]

def main [...only: string]: nothing -> nothing {
  let root = ($env.FILE_PWD | path dirname)
  $env.NU_AGENT_ROOT = $root

  let wanted = (
    if ($only | is-empty) {
      $SUITES
    } else {
      let unknown = ($only | where {|s| $SUITES | all {|k| $k.name != $s } })
      if ($unknown | is-not-empty) {
        error make { msg: $"unknown suite\(s\): ($unknown | str join ', '). known: ($SUITES | get name | str join ', ')" }
      }
      $SUITES | where {|s| $s.name in $only }
    }
  )

  mut all = []
  for s in $wanted {
    print ""
    print $"── ($s.name) — ($s.covers) ──"

    # the suite writes its result JSON to a file rather than stdout: a suite's own
    # output can land on stdout (the `--stream` case prints the model's text
    # there), which would corrupt a stdout-based contract.
    let report = ($nu.temp-dir | path join $"nu-agent-test-($s.name)-(random int 100000..999999).json")
    $env.NU_TEST_REPORT = $report
    let r = (
      ^nu --config ($root | path join "test/config.nu") ($root | path join $"test/($s.name).nu")
      | complete
    )
    # the suite's ✓/✗ lines are on stderr; pass them through so the operator sees
    # the individual assertions
    if ($r.stderr | is-not-empty) { print -e ($r.stderr | str trim -r) }

    let parsed = (
      if ($report | path exists) {
        let p = (try { open $report } catch { null })
        rm -f $report
        $p
      } else {
        null
      }
    )
    if $parsed == null {
      print $"  ✗ ($s.name) produced no parseable result — the suite itself is broken"
      print $"    stderr tail: ($r.stderr | str trim | str substring 0..400)"
      $all = ($all | append {name: $"($s.name): suite did not run", ok: false, detail: "no result file", suite: $s.name})
    } else {
      $all = ($all | append ($parsed | each {|x| $x | insert suite $s.name }))
    }
  }

  let skipped = ($all | where {|x| $x | get --optional skipped | default false })
  let failed = ($all | where {|x| (not ($x | get --optional ok | default false)) and (not ($x | get --optional skipped | default false)) })
  let passed = ($all | where {|x| (($x | get --optional ok | default false)) and (not ($x | get --optional skipped | default false)) })

  print ""
  print "════════════════════════════════════════"
  for s in $SUITES {
    let rows = ($all | where suite == $s.name)
    if ($rows | is-not-empty) {
      let sk = ($rows | where {|x| $x | get --optional skipped | default false } | length)
      let ok = ($rows | where {|x| (($x | get --optional ok | default false)) and (not ($x | get --optional skipped | default false)) } | length)
      let bad = (($rows | length) - $ok - $sk)
      let mark = (if ($bad > 0) { "✗" } else if ($sk > 0) { "○" } else { "✓" })
      let note = (if ($sk > 0) { $", ($sk) skipped" } else { "" })
      print $"  ($mark) ($s.name): ($ok)/(($rows | length) - $sk)($note)"
    }
  }
  print $"  total: ($passed | length) passed, ($failed | length) failed, ($skipped | length) skipped"
  print "════════════════════════════════════════"

  if ($failed | is-not-empty) {
    print ""
    print "failures:"
    for f in $failed {
      print $"  · ($f.name)"
      if (($f | get --optional detail | default "") | is-not-empty) {
        print $"      ($f.detail)"
      }
    }
    exit 1
  }
}
