#!/usr/bin/env nu
# mcp-server.nu — expose nushell modules as MCP tools
#
#   nu --config <your config.nu> /path/to/mcp-server.nu
#
# **--config is mandatory.** without it the process has no modules at all and the tool list
# comes out empty (measured: without → 0 modules; with → 12). with it, the tool list
# automatically tracks config.nu — no separate module manifest to maintain in this script.
#
# ── which modules get exposed: NU_MCP_MODULES ──
# comma-separated, three forms, freely mixed:
#     (unset)                      a default set of the 6 most useful to a coding agent
#     "*"                          the whole capability set (TOOL_MODULES below)
#     "*,-style,-jsonschema"       expand * then exclude a few
#     "calc,host"                  expose only the named ones
#
# ── why an explicit list and not a name prefix ──
# this used to be `scope modules | where name =~ "^nu-"`, which worked only
# because every module was named nu-*. The rename removed that prefix, so the
# regex now matches nothing and the tool list comes out empty — silently, since
# "no tools" is a legal answer. The list is also the better contract: it names
# what is being lent out, rather than inferring it from a naming convention.
#
# note what is deliberately ABSENT: `agent` (a tool that could call it would let
# the model recursively spawn the top-level loop), plus `policy`, `expose`, `mcp`
# and the provider internals — those are runtime machinery, not capabilities.
#
# `session` is absent for a narrower reason: the model has a real use for
# reading a stored transcript, but the module also carries the writers
# (`session store`, `prune`, `record-of`), and the allowlist is per module, not
# per command. lending the model eleven tools so it can reach two of them is the
# wrong trade — and `nu-shell` already reaches all of them.
#
# ── protocol notes ──
# stdio transport, newline-delimited JSON-RPC 2.0. **stdout may carry protocol
# messages only** — one extra character makes the client fail to parse, so:
#   · all logging goes to stderr
#   · | ignore at the end of the loop swallows the return value
#     (nu prints the return value of each/reduce; measured: a bare each leaks an empty table)
#
# ── why ^cat | lines ──
# the server must read requests **one at a time** and respond one at a time, it cannot wait for EOF.
# `open --raw /dev/stdin` blocks until input ends ✗;
# nu reads external processes as a stream, so ^cat | lines arrives line by line. measured.

use ./expose.nu
use ./reason.nu
use ./agent.nu

# Newest first. keep in sync with mcp.nu's PROTOCOL_VERSIONS.
# 2025-11-25 is current — read off Claude Code's own client list rather than guessed.
const PROTOCOL_VERSIONS = [
  "2025-11-25"
  "2025-06-18"
  "2025-03-26"
  "2024-11-05"
  "2024-10-07"
]
# a const cannot call a command — `($PROTOCOL_VERSIONS | first)` is a runtime
# expression, so the latest must be written out. keep the two in sync.
const PROTOCOL = "2025-11-25"
const SERVER_NAME = "agent"
const SERVER_VERSION = "0.1.0"

# the capabilities this server lends out — the contract, in one place.
# these are MODULE names, not tool names, and the two are not always the same:
# `proc` is the module and `exec` the tool it is offered as, because nu cannot
# have a command called `exec`. naming the tool here loads nothing and the module
# is skipped — silently, since a missing module is a stderr note and an empty
# tool list is a legal answer.
const TOOL_MODULES = ["read" "write" "edit" "shell" "proc" "nu-shell" "calc" "host" "remote" "peers" "image" "jsonschema" "toon" "task"]
# the default when NU_MCP_MODULES is unset: the six most useful to a coding agent
const DEFAULT_MODULES = ["read" "write" "edit" "shell"]

# parse NU_MCP_MODULES, **without expanding it**.
# expansion must happen in the child process: this process's module set is frozen at startup
# (measured: sourcing a module at runtime inside a function body — the module is gone once
#  it returns; top-level source sees 1, inside a function 0), so expanding `*` server-side is just another frozen snapshot.
def module-spec []: nothing -> list<string> {
  let raw = ($env.NU_MCP_MODULES? | default "")
  if ($raw | is-empty) {
    $DEFAULT_MODULES
  } else {
    $raw | split row ',' | each {|s| $s | str trim } | where {|s| $s | is-not-empty }
  }
}

# pull the `-xxx` exclusions out of the spec
def exclusions [spec: list<string>]: nothing -> list<string> {
  $spec | where {|s| $s | str starts-with '-' } | each {|s| $s | str substring 1.. }
}

# build the tool list in-process — reads **this process's** scope modules, i.e. the frozen snapshot.
# now only a fallback for when the child process fails.
def list-tools-inproc [spec: list<string>]: nothing -> list {
  let excl = (exclusions $spec)
  let names = (
    if ($spec | any {|s| $s == "*" }) {
      $TOOL_MODULES | where {|n| not ($n in $excl) }
    } else {
      $spec | where {|s| not ($s | str starts-with '-') }
    }
  )
  $names
  | each {|m|
      try { expose from-module $m } catch {|e| print -e $"skipping module ($m): (reason $e)"; [] }
    }
  | flatten
}

# build the MCP definition for every tool.
#
# **goes through a child process instead of reading this process's scope modules.** why:
#   tools/call already runs in a child process (agent invoke-tool → ^nu --config ...), and the
#   child re-reads config.nu every time. if list read this process's frozen snapshot while call
#   read the child's fresh config, the two would read **two different worlds** — add a module to
#   config.nu and call can already run it while list can't see it. both now share one source: config.nu.
#
# measured A/B (server never restarts; a use line is appended to config.nu while it runs):
#   this version  →  first call calc, second call calc,nu-dyntest_hello  ✓
#   old version   →  first call calc, second call calc (never sees it)   ✗
#
# note MCP names the key inputSchema (camelCase) while Anthropic uses input_schema,
# the only format difference between the two.
def list-tools []: nothing -> list {
  let spec = (module-spec)
  # single-quoted so the outer interpolation doesn't swallow $m / $e
  let body = '| each {|m| try { expose from-module $m } catch {|e| print -e $"skipping module ($m): (reason $e)"; [] } } | flatten | to json -r'

  # `*` resolves to TOOL_MODULES here, at build time — it is a constant, so unlike
  # the old prefix regex there is nothing for the child to expand. Exclusions
  # still apply. Only the explicit-name form was ever computed in the child.
  #
  # this **must be assembled with single-quote concatenation**, never $"..." — double-quoted interpolation
  # swallows the inner script's $m / $e as outer variables and errors with variable not found (been there).
  let head = (
    if ($spec | any {|s| $s == "*" }) {
      (($TOOL_MODULES | where {|n| not ($n in (exclusions $spec)) }) | to nuon)
    } else {
      (($spec | where {|s| not ($s | str starts-with '-') }) | to nuon)
    }
  )

  let r = (^nu --config $nu.config-path -c ($head + " " + $body) | complete)
  # the child's stderr carries diagnostics like "skipping module X" — don't swallow them
  if ($r.stderr | is-not-empty) { print -e ($r.stderr | str trim) }

  let tools = (
    if $r.exit_code != 0 {
      print -e "child process failed to list tools, falling back to in-process"
      list-tools-inproc $spec
    } else {
      try { $r.stdout | from json } catch {|e|
        print -e $"parsing the tool list failed, falling back to in-process: (reason $e)"
        list-tools-inproc $spec
      }
    }
  )

  $tools
  | each {|t|
      {
        name: $t.name
        description: ($t | get --optional description | default "")
        inputSchema: ($t | get --optional input_schema | default {type: "object", properties: {}})
      }
    }
}

def send [msg: record]: nothing -> nothing {
  # to json -r is compact and single-line; newlines inside are escaped as \n, so framing stays intact
  print ($msg | to json -r)
}

def reply [id: any, result: any]: nothing -> nothing {
  send {jsonrpc: "2.0", id: $id, result: $result}
}

def reply-err [id: any, code: int, message: string]: nothing -> nothing {
  send {jsonrpc: "2.0", id: $id, error: {code: $code, message: $message}}
}

def handle [msg: record]: nothing -> nothing {
  let method = ($msg | get --optional method | default "")
  let id = ($msg | get --optional id)
  let params = ($msg | get --optional params | default {})

  # notifications have no id, and the protocol says **not** to answer them
  if $id == null {
    print -e $"notification: ($method)"
    return
  }

  if $method == "initialize" {
    # Negotiate: echo the client's version when we support it, otherwise offer ours.
    # That is what the spec asks for, and it is why an older client still works.
    let asked = ($params | get --optional protocolVersion | default "")
    let chosen = (if $asked in $PROTOCOL_VERSIONS { $asked } else { $PROTOCOL })
    print -e $"client asked protocol ($asked) → using ($chosen)"
    reply $id {
      protocolVersion: $chosen
      capabilities: {tools: {}}
      serverInfo: {name: $SERVER_NAME, version: $SERVER_VERSION}
    }
    return
  }

  if $method == "ping" {
    reply $id {}
    return
  }

  if $method == "tools/list" {
    reply $id {tools: (list-tools)}
    return
  }

  if $method == "tools/call" {
    let name = ($params | get --optional name | default "")
    let args = ($params | get --optional arguments | default {})
    print -e $"calling tool: ($name)"
    # reuse the execution machinery from agent.nu: the same call record shape.
    # note `use agent.nu` imports a namespace, so it has to be agent invoke-tool —
    # a bare invoke-tool errors with External command failed (been there)
    # the 4th argument is the TOOL deadline: past it the tool is killed and the model gets a
    # failure instead of a hang. it used to be `120sec` here, and nothing enforced it — the
    # parameter was accepted and ignored until invoke-tool learned to run a watchdog.
    let r = (try {
        agent invoke-tool {name: $name, input: $args, id: "mcp"} null 8000 300sec false
      } catch {|e|
        {content: $"tool execution failed: (reason $e)", is_error: true}
      })
    reply $id {
      content: [{type: "text", text: ($r | get --optional content | default "" | into string)}]
      isError: ($r | get --optional is_error | default false)
    }
    return
  }

  reply-err $id -32601 $"unknown method: ($method)"
}

# ── main loop ──
# self-check: how many of the capability modules actually made it into this
# process. without --config there are none and the tool list would be empty —
# better to say so at startup than to hand the client an empty list and let it wonder.
#
# this used to count modules matching `^nu-`. The rename removed that prefix, so a
# prefix test now reports 0 even on a perfectly healthy start — it would cry wolf
# on every run. count the allowlist instead, which cannot drift from the rename.
let present = (scope modules | get name)
let loaded = ($TOOL_MODULES | where {|m| $m in $present } | length)
if $loaded == 0 {
  print -e "⚠ no capability modules in this process — most likely --config was left off at startup. correct usage:"
  print -e $"    nu --config ($nu.config-path) (($nu.current-exe) | path dirname)/../core/mcp-server.nu"
  print -e "  (the tool list will be empty, but the server still responds normally)"
}
print -e $"agent MCP server started · protocol ($PROTOCOL) · ($loaded)/($TOOL_MODULES | length) capabilities · spec: (module-spec | str join ', ')"

^cat
| lines
| reduce --fold 0 {|line, n|
    let s = ($line | str trim)
    if ($s | is-empty) {
      $n
    } else {
      let msg = (try { $s | from json } catch {|e| print -e $"JSON parse failed: (reason $e)"; null })
      if $msg != null { handle $msg }
      $n + 1
    }
  }
| ignore
