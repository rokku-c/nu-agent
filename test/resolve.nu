#!/usr/bin/env nu
# resolve.nu — module-resolution regression tests
#
# these exist because resolution is the part that bit hardest during the port,
# and the failure mode is silent: a tool list that comes out empty is a *legal*
# answer, so a broken install looks like an install with nothing to offer.
#
# the two measured traps this guards against:
#   · NU_LIB_DIRS is stripped from child processes, and every tool call is a
#     child process — so anything resolved through it works at the prompt and
#     fails on every call.
#   · two modules with the same file stem MERGE instead of shadowing, and a
#     same-named command inside them is silently won by whichever loaded later.

use ./harness.nu *

let ROOT = ($env.NU_AGENT_ROOT? | default "")

# the capability modules — keep in sync with install.nu and mcp-server.nu
const TOOL_MODULES = ["edit" "host" "image" "jsonschema" "nu-shell" "peers" "read" "remote" "shell" "toon" "write"]
# nu builtins that a module name must not collide with
const TAKEN_NAMES = ["http" "reduce" "schema"]

def stems [dir: path]: nothing -> list<string> {
  glob ($dir | path join "*.nu") | each {|f| $f | path parse | get stem }
}

let results = [
  # ── the big one: resolution inside a CHILD process ──
  (case "resolve: modules load in a child process (the tool-call path)" {
    # this is exactly how invoke-tool spawns a tool: a fresh nu, --config, -c
    let r = (^nu --config $nu.config-path -c 'scope modules | where {|m| $m.name !~ "^prelude" } | get name | to json -r' | complete)
    if $r.exit_code != 0 {
      error make { msg: $"child failed: ($r.stderr | str trim)" }
    }
    let loaded = ($r.stdout | str trim | from json)
    (is-true "resolve: modules load in a child process (the tool-call path)" (($loaded | length) >= 18))
  })

  (case "resolve: a capability actually RUNS in a child process" {
    # loading is not enough — the command has to be callable there, which is what
    # build-script assembles into the subprocess
    let r = (^nu --config $nu.config-path -c 'do { calc "(6*7)" }' | complete)
    (eq "resolve: a capability actually RUNS in a child process" ($r.stdout | str trim) "42")
  })

  (case "resolve: a grandchild process still resolves" {
    # MCP server → invoke-tool → tool is two levels of nesting. rather than fight
    # quote-escaping three deep — a `(` inside $"..." is an interpolation even
    # when the quotes around it are escaped — write each level to a script file.
    # the paths hold no quotes, so nothing here can be confused with the subject
    # under test, which is resolution.
    let g = ($nu.temp-dir | path join "nu-agent-grandchild.nu")
    'calc "(6*7)"' | save -f $g
    let c = ($nu.temp-dir | path join "nu-agent-child.nu")
    $"^nu --config ($nu.config-path) ($g)" | save -f $c
    let r = (^nu --config $nu.config-path $c | complete)
    rm -f $g $c
    (eq "resolve: a grandchild process still resolves" ($r.stdout | str trim) "42")
  })

  # ── stem uniqueness (measured: same stem == silent merge) ──
  (case "resolve: core/ and tools/ have no colliding file stems" {
    let all = ((stems $"($ROOT)/core") | append (stems $"($ROOT)/tools"))
    let dupes = ($all | uniq -d)
    (eq "resolve: core/ and tools/ have no colliding file stems" $dupes [])
  })

  (case "resolve: no module takes a name nu already owns" {
    let all = ((stems $"($ROOT)/core") | append (stems $"($ROOT)/tools"))
    let clash = ($all | where {|s| $s in $TAKEN_NAMES })
    (eq "resolve: no module takes a name nu already owns" $clash [])
  })

  # ── the naming contract ──
  (case "resolve: every module is named without a nu- prefix" {
    let all = ((stems $"($ROOT)/core") | append (stems $"($ROOT)/tools"))
    let bad = ($all | where {|s| ($s | str starts-with "nu-") and $s != "nu-shell" })
    (eq "resolve: every module is named without a nu- prefix" $bad [])
  })

  (case "resolve: every capability module yields at least one tool" {
    let empty = ($TOOL_MODULES | where {|m| (expose from-module $m | length) == 0 })
    (eq "resolve: every capability module yields at least one tool" $empty [])
  })

  (case "resolve: no generated tool name carries a stray nu- prefix" {
    let names = ($TOOL_MODULES | each {|m| expose from-module $m } | flatten | get name)
    let bad = ($names | where {|n| ($n | str starts-with "nu-") and $n != "nu-shell" })
    (eq "resolve: no generated tool name carries a stray nu- prefix" $bad [])
  })

  (case "resolve: nu-shell is kept, because it hands over nushell itself" {
    let names = ($TOOL_MODULES | each {|m| expose from-module $m } | flatten | get name)
    (is-true "resolve: nu-shell is kept, because it hands over nushell itself" ($names | any {|n| $n == "nu-shell" }))
  })

  (case "resolve: the runtime modules are NOT offered as tools" {
    # agent / policy / expose / mcp / layout / quote are machinery, not capabilities.
    # `agent` above all: a tool that could call it lets the model recursively spawn
    # the top-level loop.
    let names = ($TOOL_MODULES | each {|m| expose from-module $m } | flatten | get name)
    let leaked = ($names | where {|n| ($n == "agent") or ($n | str starts-with "agent_") })
    (eq "resolve: the runtime modules are NOT offered as tools" $leaked [])
  })

  (case "resolve: internal helpers stay out of the top-level module scope" {
    # layout and quote are used only *inside* other modules, which is what keeps
    # them from becoming tools (measured: a plain, non-export `use` inside a
    # module does not surface the submodule in top-level `scope modules`)
    let mods = (scope modules | get name)
    let hidden = ($mods | where {|m| $m in ["layout" "quote"] })
    (eq "resolve: internal helpers stay out of the top-level module scope" $hidden [])
  })
]

emit $results
