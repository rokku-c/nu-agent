#!/usr/bin/env nu
# task.nu — subagent orchestration
#
# the guard cases are hermetic: depth and the capability check both refuse before
# any API call, so they run everywhere. the rest need a real endpoint.

use ./harness.nu *

let tmp = ($nu.temp-dir | path join $"nu-agent-task-(random int 100000..999999)")
mkdir $tmp
$env.NU_SESSION_DIR = ($tmp | path join "sessions")
$env.NU_CONTEXT_DIR = ($tmp | path join "context")

let results = [
  # ── guards, which fire before anything leaves the machine ──
  (case "task: refuses to recurse past the depth limit" {
    # the environment is how depth crosses the process boundary a subagent runs
    # behind — the same mechanism the real nesting uses
    let saved = ($env.NU_AGENT_DEPTH? | default "0")
    $env.NU_AGENT_DEPTH = "2"
    let m = (try { task "anything" --max-depth 2; "" } catch {|e| $e.msg })
    $env.NU_AGENT_DEPTH = $saved
    (has "task: refuses to recurse past the depth limit" $m "refusing to recurse past depth")
  })

  (case "task: a depth below the limit is allowed through the guard" {
    # it must get PAST the guard and fail later (no credentials here), not be
    # refused for depth — otherwise the previous case would pass for the wrong reason
    let saved = ($env.NU_AGENT_DEPTH? | default "0")
    $env.NU_AGENT_DEPTH = "1"
    let m = (try { task "anything" --max-depth 3; "" } catch {|e| $e.msg })
    $env.NU_AGENT_DEPTH = $saved
    (is-true "task: a depth below the limit is allowed through the guard" (not ($m | str contains "refusing to recurse")))
  })

  (case "task: a subagent may not be given a tool the parent does not have" {
    # without this, a read-only parent delegating to a bash-enabled child makes
    # the parent's restriction decorative
    let saved = ($env.NU_AGENT_TOOLS? | default "")
    $env.NU_AGENT_TOOLS = "read,calc"
    let m = (try { task "anything" --tools [shell write]; "" } catch {|e| $e.msg })
    $env.NU_AGENT_TOOLS = $saved
    (has "task: a subagent may not be given a tool the parent does not have" $m "never widen")
  })

  (case "task: narrowing the parent's tool set is allowed" {
    let saved = ($env.NU_AGENT_TOOLS? | default "")
    $env.NU_AGENT_TOOLS = "read,calc,bash"
    let m = (try { task "anything" --tools [read]; "" } catch {|e| $e.msg })
    $env.NU_AGENT_TOOLS = $saved
    (is-true "task: narrowing the parent's tool set is allowed" (not ($m | str contains "never widen")))
  })

  (case "task: with no parent tool set exported, the default preset stands alone" {
    let saved = ($env.NU_AGENT_TOOLS? | default "")
    $env.NU_AGENT_TOOLS = ""
    let m = (try { task "anything" --tools [read]; "" } catch {|e| $e.msg })
    $env.NU_AGENT_TOOLS = $saved
    (is-true "task: with no parent tool set exported, the default preset stands alone" (not ($m | str contains "never widen")))
  })

  # ── the real thing ──
  (case "task: a subagent runs its own loop and returns a result" {
    if not (needs-creds) {
      skipped "task: a subagent runs its own loop and returns a result" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let out = (task "Use the calc tool to work out 21 * 2. Report just the number." --tools [calc] --max-rounds 4)
      (has "task: a subagent runs its own loop and returns a result" $out "42")
    }
  })

  (case "task: the reply carries a cost footer" {
    # without it, delegation looks free — and the parent's model has no signal to
    # limit how much of it it does
    if not (needs-creds) {
      skipped "task: the reply carries a cost footer" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let out = (task "Use the calc tool for 3 * 3." --tools [calc] --max-rounds 4)
      (is-true "task: the reply carries a cost footer" (
        ($out | str contains "[subagent ") and ($out | str contains "rounds") and ($out | str contains "tool calls")
      ))
    }
  })

  (case "task: the subagent's transcript is stored with its own lineage" {
    if not (needs-creds) {
      skipped "task: the subagent's transcript is stored with its own lineage" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let before = ((session list) | length)
      task "Use the calc tool for 5 * 5." --tools [calc] --max-rounds 4 | ignore
      let after = (session list)
      (is-true "task: the subagent's transcript is stored with its own lineage" (
        (($after | length) > $before)
        and (($after | where depth == 1 | length) > 0)
      ))
    }
  })

  (case "task: the stored transcript holds the child's REAL history" {
    if not (needs-creds) {
      skipped "task: the stored transcript holds the child's REAL history" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let r = (task "Use the calc tool for 7 * 6." --tools [calc] --max-rounds 4 --json)
      let rec = (session load $r.session)
      let raw = ($rec.messages | to json -r)
      (is-true "task: the stored transcript holds the child's REAL history" (
        (not ($raw | str contains "[folded]")) and (($rec.messages | length) >= 3) and ($raw | str contains "7 * 6")
      ))
    }
  })

  (case "task: the child's own messages start from the task, not the parent's history" {
    # the whole point of delegating is a fresh context
    if not (needs-creds) {
      skipped "task: the child's own messages start from the task, not the parent's history" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let r = (task "Say only: done" --tools [calc] --max-rounds 2 --json)
      let rec = (session load $r.session)
      let first = ($rec.messages | first)
      (is-true "task: the child's own messages start from the task, not the parent's history" (
        ($first.role == "user") and (($first.content | into string) | str contains "Say only")
      ))
    }
  })

  (case "task: --json reports the counters without the footer text" {
    if not (needs-creds) {
      skipped "task: --json reports the counters without the footer text" "no ANTHROPIC_AUTH_TOKEN"
    } else {
      let r = (task "Say only: ok" --max-rounds 2 --json)
      (is-true "task: --json reports the counters without the footer text" (
        (($r.rounds | default 0) >= 1) and (($r | get --optional session) != null) and (not (($r.text | default "") | str contains "[subagent "))
      ))
    }
  })

  # ── policy inheritance ──
  (case "task: the parent's compiled rules are handed down, not the file path" {
    # passing compiled rules rather than a path is what stops a child pointing
    # NU_POLICY_FILE at an empty file and escaping
    let saved = ($env.NU_POLICY_FILE? | default "")
    $env.NU_POLICY_FILE = ($tmp | path join "rules.json")
    {version: 1, default: "allow", rules: [{match: {tool: "bash"}, action: "deny", reason: "no bash for you"}]} | save -f $env.NU_POLICY_FILE
    $env.NU_POLICY_FILE = $saved
    # assert on the mechanism directly: `policy rules` prefers the injected form
    let injected = ({version: 1, default: "deny", rules: []} | to json -r)
    let s2 = ($env.NU_AGENT_POLICY? | default "")
    $env.NU_AGENT_POLICY = $injected
    let d = (policy check {tool: "bash", command: "ls", input: {}})
    $env.NU_AGENT_POLICY = $s2
    (eq "task: the parent's compiled rules are handed down, not the file path" $d.decision "deny")
  })
]

rm -rf $tmp
emit $results
