# mcp.nu — a minimal MCP client over stdio
#
#   use mcp.nu
#   mcp tools [nu --config /path/config.nu /path/mcp-server.nu]
#   mcp call  [nu --config ... mcp-server.nu] calc {expr: "6*7"}
#
# The server is given as an argv LIST, never as a command string. Handing a
# string to a shell re-splits it on spaces, so `--config /Users/…/Application
# Support/nushell/config.nu` becomes `--config /Users/…/Application` and the
# server dies on a missing file. argv has no such failure mode.
#
# ── transport: one subprocess per operation ──
# nu has no clean way to hold a bidirectional conversation with a long-lived
# child process — you cannot write a line to its stdin and read its stdout line
# by line from the same nu process. So each operation spawns the server, does
# the handshake, sends its request, reads the reply and lets it exit.
#
# That is correct and leaks nothing; the cost is the server's startup on every
# call. For an HTTP-backed server that is nil. For mcp-server it is the config load
# (about a second), which is the price of talking to a server that needs your
# modules.
#
# Sending everything at once is what makes this work: the whole request sequence
# goes in on stdin, and the replies come back on stdout, read by `complete`.

const CLIENT_NAME = "mcp"
const CLIENT_VERSION = "0.1.0"

# Newest first — the order a client offers and a server echoes from.
# Measured from Claude Code's own client list (its binary carries the array).
export const PROTOCOL_VERSIONS = [
  "2025-11-25"
  "2025-06-18"
  "2025-03-26"
  "2024-11-05"
  "2024-10-07"
]

def rpc-request [id: int, method: string, params: any]: nothing -> string {
  ({jsonrpc: "2.0", id: $id, method: $method, params: $params} | to json -r)
}

def rpc-notification [method: string]: nothing -> string {
  ({jsonrpc: "2.0", method: $method} | to json -r)
}

def init-requests []: nothing -> list<string> {
  [
    (rpc-request 1 "initialize" {
      protocolVersion: ($PROTOCOL_VERSIONS | first)
      capabilities: {}
      clientInfo: {name: $CLIENT_NAME, version: $CLIENT_VERSION}
    })
    (rpc-notification "notifications/initialized")
  ]
}

# Send every request, return the parsed JSON-RPC replies.
# Anything on stdout that is not a JSON object is ignored — a well-behaved
# server keeps stdout protocol-only, but a sloppy one may print banners.
def session [argv: list<string>, requests: list<string>]: nothing -> list {
  let input = ($requests | str join (char nl))
  # run-external with argv: no shell, so nothing re-splits the arguments
  let r = ($input | run-external ($argv | first) ...($argv | skip 1) | complete)
  if ($r.exit_code != 0) and (($r.stdout | str trim) | is-empty) {
    error make { msg: $"server exited ($r.exit_code) with no reply: ($r.stderr | str trim | str substring 0..300)" }
  }
  $r.stdout
  | lines
  | each {|l| $l | str trim }
  | where {|l| $l | str starts-with "{" }
  | each {|l| try { $l | from json } catch { null } }
  | compact
  | where {|m| ($m | get --optional jsonrpc) == "2.0" }
}

def reply-for [replies: list, id: int]: nothing -> any {
  let hit = ($replies | where {|m| ($m | get --optional id) == $id })
  if ($hit | is-empty) { return null }
  let m = ($hit | first)
  let err = ($m | get --optional error)
  if $err != null {
    error make { msg: $"server error: ($err | to json -r)" }
  }
  $m | get --optional result
}

# Handshake and return {protocol, server, capabilities} as the server reported them.
export def handshake [argv: list<string>]: nothing -> record {
  let replies = (session $argv (init-requests))
  let res = (reply-for $replies 1)
  if $res == null {
    error make { msg: "no initialize reply — is this an MCP server on stdio?" }
  }
  {
    # the server picks the version: ours if it supports it, otherwise its own latest
    protocol: ($res | get --optional protocolVersion | default "unknown")
    server: ($res | get --optional serverInfo | get --optional name | default "unknown")
    version: ($res | get --optional serverInfo | get --optional version | default "")
    capabilities: ($res | get --optional capabilities | default {})
  }
}

# List a server's tools, already converted to the Anthropic tool shape
# (inputSchema -> input_schema is the only difference between the two formats).
export def tools [argv: list<string>]: nothing -> list {
  let replies = (session $argv (init-requests | append (rpc-request 2 "tools/list" {})))
  let res = (reply-for $replies 2)
  if $res == null { return [] }
  ($res | get --optional tools | default [])
  | each {|t|
      {
        name: ($t | get --optional name | default "")
        description: ($t | get --optional description | default "")
        input_schema: ($t | get --optional inputSchema | default {type: "object", properties: {}})
      }
    }
}

# Call a tool. Returns the result text plus whether the server flagged it as an error.
export def call [argv: list<string>, tool: string, args: record]: nothing -> record {
  let replies = (
    session $argv (
      init-requests | append (rpc-request 2 "tools/call" {name: $tool, arguments: $args})
    )
  )
  let res = (reply-for $replies 2)
  if $res == null {
    error make { msg: $"no reply to tools/call ($tool)" }
  }

  # content is a list of blocks; join the text ones
  let text = (
    ($res | get --optional content | default [])
    | each {|b|
        let t = ($b | get --optional type | default "")
        if $t == "text" { ($b | get --optional text | default "") } else { $"[($t) block]" }
      }
    | str join (char nl)
  )

  {
    text: (if ($text | str trim | is-empty) { "(no content)" } else { $text })
    is_error: ($res | get --optional isError | default false)
  }
}
