#!/usr/bin/env nu
# mcp.nu — MCP protocol tests against the real server, over real stdio
#
# the server is spawned exactly as a client would spawn it, and driven with the
# same client module the agent loop uses for external servers — so this covers
# both sides of the wire.

use ./harness.nu *

let ROOT = ($env.NU_AGENT_ROOT? | default "")

def server-argv []: nothing -> list<string> {
  ["nu" "--config" $"($ROOT)/test/config.nu" $"($ROOT)/core/mcp-server.nu"]
}

# raw stdio: send JSON-RPC lines in, return {stdout, stderr, exit_code}
def raw-session [requests: list<string>]: nothing -> record {
  let input = ($requests | str join (char nl))
  $input | run-external "nu" "--config" $"($ROOT)/test/config.nu" $"($ROOT)/core/mcp-server.nu" | complete
}

let results = [
  (case "mcp: handshake reports the server as 'agent'" {
    let h = (mcp handshake (server-argv))
    (eq "mcp: handshake reports the server as 'agent'" $h.server "agent")
  })

  (case "mcp: handshake negotiates a protocol version we know" {
    let h = (mcp handshake (server-argv))
    (is-true "mcp: handshake negotiates a protocol version we know" ($h.protocol in $mcp.PROTOCOL_VERSIONS))
  })

  (case "mcp: tools/list returns the default capability set" {
    # NU_MCP_MODULES unset -> DEFAULT_MODULES = read write edit shell: the four a
    # coding agent reaches for, and nothing else
    let names = (mcp tools (server-argv) | get name | sort)
    (eq "mcp: tools/list returns the default capability set" $names ["edit" "read" "shell" "write"])
  })

  (case "mcp: the allowlist names modules, so proc is offered as exec" {
    # naming the TOOL in the allowlist loads nothing, and the failure is silent:
    # a missing module is a stderr note while an empty tool list is a legal
    # answer. `exec` is a nushell parser keyword, so the module is `proc` and the
    # rename happens in expose — which means the allowlist must say `proc`.
    let r = (with-env {NU_MCP_MODULES: "*"} { mcp tools (server-argv) | get name })
    (has "mcp: the allowlist names modules, so proc is offered as exec" ($r | str join ",") "exec")
  })

  (case "mcp: 'nu-shell' is the only nu- prefixed tool offered" {
    let names = (mcp tools (server-argv) | get name)
    let bad = ($names | where {|n| ($n | str starts-with "nu-") and $n != "nu-shell" })
    (eq "mcp: 'nu-shell' is the only nu- prefixed tool offered" $bad [])
  })

  (case "mcp: tools carry a usable input_schema, not an empty one" {
    let read = (mcp tools (server-argv) | where name == "read" | first)
    (is-true "mcp: tools carry a usable input_schema, not an empty one" (($read.input_schema.properties | columns | length) > 0))
  })

  (case "mcp: an MCP tool uses camelCase inputSchema on the wire, input_schema here" {
    # the client translates between the two; the only format difference between
    # the Anthropic and MCP tool shapes
    let t = (mcp tools (server-argv) | where name == "read" | first)
    (is-true "mcp: an MCP tool uses camelCase inputSchema on the wire, input_schema here" ($t.input_schema != null))
  })

  (case "mcp: tools/call actually executes a capability" {
    let r = (mcp call (server-argv) "shell" {command: "echo $((6*7))"})
    (eq "mcp: tools/call actually executes a capability" ($r.text | str trim) "42")
  })

  (case "mcp: a failing tool comes back as is_error, not as a crash" {
    # the loop needs a tool failure to be a result it can hand back to the model,
    # otherwise one bad call takes the whole run down
    let r = (mcp call (server-argv) "shell" {command: "exit 3"})
    (is-true "mcp: a failing tool comes back as is_error, not as a crash" ($r.is_error and ($r.text | str length) > 0))
  })

  (case "mcp: calling an unknown tool is an error, not a hang" {
    let r = (mcp call (server-argv) "no_such_tool_at_all" {})
    (is-true "mcp: calling an unknown tool is an error, not a hang" $r.is_error)
  })

  (case "mcp: stdout carries protocol messages only" {
    # one stray character on stdout and the client cannot parse the stream.
    # everything human goes to stderr — asserted here because a single `print`
    # added in the wrong place breaks every client, and nothing else would catch it.
    let r = (raw-session [
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'
      '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      '{"jsonrpc":"2.0","id":3,"method":"no/such/method","params":{}}'
    ])
    let lines = ($r.stdout | lines | where {|l| ($l | str trim) | is-not-empty })
    let unparseable = ($lines | where {|l| (try { $l | from json; false } catch { true }) })
    (eq "mcp: stdout carries protocol messages only" $unparseable [])
  })

  (case "mcp: every JSON-RPC reply carries the right id" {
    let r = (raw-session [
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      '{"jsonrpc":"2.0","id":9,"method":"ping","params":{}}'
    ])
    let ids = ($r.stdout | lines | where {|l| ($l | str trim) | is-not-empty } | each {|l| $l | from json | get id } | sort)
    (eq "mcp: every JSON-RPC reply carries the right id" $ids [1 2 9])
  })

  (case "mcp: an unknown method is answered with -32601, not silence" {
    let r = (raw-session [
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'
      '{"jsonrpc":"2.0","id":7,"method":"nope/nope","params":{}}'
    ])
    let reply = ($r.stdout | lines | where {|l| ($l | str trim) | is-not-empty } | each {|l| $l | from json } | where id == 7 | first)
    (eq "mcp: an unknown method is answered with -32601, not silence" $reply.error.code (-32601))
  })

  (case "mcp: notifications are never answered (id-less requests)" {
    let r = (raw-session [
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'
      '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    ])
    let replies = ($r.stdout | lines | where {|l| ($l | str trim) | is-not-empty })
    # exactly one reply: the initialize. the notification must not be answered.
    (eq "mcp: notifications are never answered (id-less requests)" ($replies | length) 1)
  })

  (case "mcp: server startup diagnostics go to stderr, not stdout" {
    let r = (raw-session ['{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}'])
    (has "mcp: server startup diagnostics go to stderr, not stdout" $r.stderr "agent MCP server started")
  })
]

emit $results
