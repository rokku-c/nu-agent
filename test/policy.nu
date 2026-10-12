#!/usr/bin/env nu
# policy.nu — the tool permission gate
#
# hermetic: no network, and every rules file is written into a temp dir, so a
# real $nu.default-config-dir/agent-policy.json is never read or touched.

use ./harness.nu *

let tmp = ($nu.temp-dir | path join $"nu-agent-policy-(random int 100000..999999)")
mkdir $tmp
$env.NU_CONTEXT_DIR = ($tmp | path join "context")
$env.NU_POLICY_FILE = ($tmp | path join "rules.json")

# a rules file exercising all three match keys, first-match-wins, and a custom default
{version: 1, default: "allow", rules: [
  {match: {tool: "bash", command: "*rm -rf*"}, action: "deny", reason: "no recursive deletes"}
  {match: {tool: "read", path: "*id_rsa*"}, action: "deny", reason: "private keys"}
  {match: {tool: "write", path: "/etc/*"}, action: "ask", reason: "system config"}
  {match: {tool: "calc"}, action: "allow"}
]} | save -f $env.NU_POLICY_FILE

let results = [
  # ── the default posture ──
  (case "policy: with no rules file the gate is open" {
    let saved = $env.NU_POLICY_FILE
    $env.NU_POLICY_FILE = ($tmp | path join "does-not-exist.json")
    let d = (policy check {tool: "bash", command: "ls", input: {}})
    let src = $d.source
    $env.NU_POLICY_FILE = $saved
    (eq "policy: with no rules file the gate is open" [$d.decision $src] ["allow" "none"])
  })

  (case "policy: the default is allow, so an unlisted call runs" {
    let d = (policy check {tool: "bash", command: "ls -la", input: {}})
    (eq "policy: the default is allow, so an unlisted call runs" $d.decision "allow")
  })

  # ── matching ──
  (case "policy: a command glob matches the assembled command line" {
    let d = (policy check {tool: "bash", command: "bash \"rm -rf /tmp/x\"", input: {}})
    (eq "policy: a command glob matches the assembled command line" $d.decision "deny")
  })

  (case "policy: a glob does not match a near-miss" {
    # the pattern is `*rm -rf*`, so a plain `rm` must not trip it
    let d = (policy check {tool: "bash", command: "bash \"rm /tmp/x\"", input: {}})
    (eq "policy: a glob does not match a near-miss" $d.decision "allow")
  })

  (case "policy: a tool glob matches on the tool name the model sees" {
    let d = (policy check {tool: "calc", command: "calc \"1+1\"", input: {}})
    (eq "policy: a tool glob matches on the tool name the model sees" $d.decision "allow")
  })

  (case "policy: a path pattern matches a path-ish argument" {
    let d = (policy check {tool: "read", command: "", input: {path: "/home/u/.ssh/id_rsa"}})
    (eq "policy: a path pattern matches a path-ish argument" $d.decision "deny")
  })

  (case "policy: a path rule ignores calls whose path does not match" {
    let d = (policy check {tool: "read", command: "", input: {path: "/etc/hosts"}})
    (eq "policy: a path rule ignores calls whose path does not match" $d.decision "allow")
  })

  (case "policy: a tool and command together must BOTH match" {
    # rule 1 is tool=read + path=*id_rsa*. a bash call carrying that path must
    # not trip it — an AND across keys, not an OR
    let d = (policy check {tool: "bash", command: "cat /home/u/.ssh/id_rsa", input: {path: "/home/u/.ssh/id_rsa"}})
    (eq "policy: a tool and command together must BOTH match" $d.decision "allow")
  })

  (case "policy: path-ish arguments are found by key name, not position" {
    # tool schemas vary, so a key containing path/cwd/file counts
    let d = (policy check {tool: "write", command: "", input: {some_path: "/etc/nginx/nginx.conf"}})
    (eq "policy: path-ish arguments are found by key name, not position" $d.decision "ask")
  })

  (case "policy: the first matching rule wins" {
    let d = (policy check {tool: "bash", command: "bash \"rm -rf /tmp/x\"", input: {}})
    (eq "policy: the first matching rule wins" $d.rule 0)
  })

  (case "policy: a decided call reports which rule decided it" {
    let d = (policy check {tool: "read", command: "", input: {path: "/home/u/.ssh/id_rsa"}})
    (eq "policy: a decided call reports which rule decided it" $d.rule 1)
  })

  (case "policy: an undecided call reports no rule" {
    let d = (policy check {tool: "bash", command: "ls", input: {}})
    (eq "policy: an undecided call reports no rule" $d.rule null)
  })

  (case "policy: check does not raise on a denial — deciding and enforcing are separate" {
    # the caller decides what to do; a gate that threw while merely being asked
    # could not be used to explain a rules file
    let d = (policy check {tool: "bash", command: "bash \"rm -rf /\"", input: {}})
    (eq "policy: check does not raise on a denial — deciding and enforcing are separate" $d.decision "deny")
  })

  # ── the message the model reads ──
  (case "policy: the refusal names the command, the rule and the reason" {
    let d = (policy check {tool: "bash", command: "bash \"rm -rf /tmp/x\"", input: {}})
    let m = (policy refuse-message $d)
    (is-true "policy: the refusal names the command, the rule and the reason" (
      ($m | str contains "rm -rf /tmp/x") and ($m | str contains "rule 0") and ($m | str contains "no recursive deletes")
    ))
  })

  (case "policy: the refusal tells the model not to retry" {
    # without this the model will simply re-issue the call
    let d = (policy check {tool: "bash", command: "bash \"rm -rf /tmp/x\"", input: {}})
    (has "policy: the refusal tells the model not to retry" (policy refuse-message $d) "do not retry")
  })

  (case "policy: the refusal points the model at the user, not at a workaround" {
    let d = (policy check {tool: "bash", command: "bash \"rm -rf /tmp/x\"", input: {}})
    (has "policy: the refusal points the model at the user, not at a workaround" (policy refuse-message $d) "amend the policy")
  })

  # ── enforcement through the tool executor ──
  (case "policy: an allowed call still runs, unchanged" {
    let r = (agent invoke-tool {name: "calc", input: {expr: "6*7"}, id: "t1"} null 8000 60sec false)
    (is-true "policy: an allowed call still runs, unchanged" ((not $r.is_error) and ($r.content | str contains "42")))
  })

  (case "policy: a denied call returns an is_error tool result, not an exception" {
    # this is the contract: the loop must be able to hand the denial back to the
    # model, so invoke-tool has to return rather than tear the run down
    let r = (agent invoke-tool {name: "bash", input: {command: "rm -rf /tmp/nope"}, id: "t2"} null 8000 60sec false)
    (is-true "policy: a denied call returns an is_error tool result, not an exception" ($r.is_error == true))
  })

  (case "policy: the tool result carries the refusal text for the model" {
    let r = (agent invoke-tool {name: "bash", input: {command: "rm -rf /tmp/nope"}, id: "t3"} null 8000 60sec false)
    (has "policy: the tool result carries the refusal text for the model" $r.content "do not retry")
  })

  (case "policy: a denied call does not execute" {
    # the proof that it was blocked rather than merely reported: a command that
    # would leave a file behind leaves no file
    let canary = ($tmp | path join "canary")
    let r = (agent invoke-tool {name: "bash", input: {command: $"touch ($canary); rm -rf /tmp/whatever"}, id: "t4"} null 8000 60sec false)
    (is-true "policy: a denied call does not execute" (not ($canary | path exists)))
  })

  # ── ask / defer ──
  (case "policy: on-ask defaults to defer when there is no terminal" {
    let saved = ($env.NU_AGENT_ON_ASK? | default "")
    $env.NU_AGENT_ON_ASK = ""
    let m = (policy on-ask-mode)
    $env.NU_AGENT_ON_ASK = $saved
    # the test run's stderr is captured, so there is nobody to prompt
    (eq "policy: on-ask defaults to defer when there is no terminal" $m "defer")
  })

  (case "policy: on-ask can be forced from the environment" {
    let saved = ($env.NU_AGENT_ON_ASK? | default "")
    $env.NU_AGENT_ON_ASK = "deny"
    let m = (policy on-ask-mode)
    $env.NU_AGENT_ON_ASK = $saved
    (eq "policy: on-ask can be forced from the environment" $m "deny")
  })

  (case "policy: an ask becomes a deferral with an id" {
    let d = (policy check {tool: "write", command: "", input: {path: "/etc/nginx/nginx.conf"}})
    let out = (policy defer $d)
    (is-true "policy: an ask becomes a deferral with an id" ($out.decision == "defer" and ($out.id | str starts-with "pol-")))
  })

  (case "policy: a second deferral appends instead of clobbering the first" {
    # regression: reading the pending file and writing it back in one pipeline
    # made nu refuse outright ("pipeline input and output are the same file").
    # it only showed on the SECOND deferral, when a file existed to read.
    let before = (policy pending | length)
    let d = (policy check {tool: "write", command: "", input: {path: "/etc/other"}})
    policy defer $d | ignore
    (eq "policy: a second deferral appends instead of clobbering the first" (policy pending | length) ($before + 1))
  })

  (case "policy: a deferred call is listed as pending" {
    let ids = (policy pending | get id)
    (is-true "policy: a deferred call is listed as pending" (($ids | length) > 0))
  })

  (case "policy: a deferral can be approved, and then leaves the queue" {
    let id = (policy pending | get id | first)
    policy approve $id | ignore
    (is-true "policy: a deferral can be approved, and then leaves the queue" (not ($id in (policy pending | get id))))
  })

  (case "policy: on-ask=deny collapses an ask to a denial without deferring" {
    let saved = ($env.NU_AGENT_ON_ASK? | default "")
    $env.NU_AGENT_ON_ASK = "deny"
    let d = (policy check {tool: "write", command: "", input: {path: "/etc/x"}})
    let out = (policy defer $d)
    $env.NU_AGENT_ON_ASK = $saved
    (eq "policy: on-ask=deny collapses an ask to a denial without deferring" $out.decision "deny")
  })

  (case "policy: the deferral message tells the model to carry on, not to retry" {
    let d = (policy check {tool: "write", command: "", input: {path: "/etc/x"}})
    let out = (policy defer $d)
    let m = (policy defer-message $out)
    (is-true "policy: the deferral message tells the model to carry on, not to retry" (
      ($m | str contains "deferred pending user approval") and ($m | str contains "do not retry")
    ))
  })

  # ── injected rules (what a subagent will inherit) ──
  (case "policy: injected compiled rules beat the rules file" {
    # a subagent is handed its parent's compiled rules, so pointing
    # NU_POLICY_FILE at an empty file cannot widen what it may do
    let saved = ($env.NU_AGENT_POLICY? | default "")
    $env.NU_AGENT_POLICY = ({version: 1, default: "deny", rules: []} | to json -r)
    let d = (policy check {tool: "bash", command: "ls", input: {}})
    $env.NU_AGENT_POLICY = $saved
    (eq "policy: injected compiled rules beat the rules file" $d.decision "deny")
  })

  (case "policy: explain reports what matched, for writing a rules file" {
    let e = (policy explain {tool: "bash", command: "bash \"rm -rf /tmp/x\"", input: {}})
    (is-true "policy: explain reports what matched, for writing a rules file" ($e.matched | str contains "rule 0"))
  })

  (case "policy: a malformed rules file says what is missing" {
    let bad = ($tmp | path join "bad.json")
    {rules: []} | save -f $bad
    let saved = ($env.NU_POLICY_FILE? | default "")
    $env.NU_POLICY_FILE = $bad
    let outcome = (try { policy check {tool: "bash", command: "ls", input: {}}; "no error" } catch {|e| $e.msg })
    $env.NU_POLICY_FILE = $saved
    (has "policy: a malformed rules file says what is missing" $outcome "missing required field")
  })
]

rm -rf $tmp
emit $results
