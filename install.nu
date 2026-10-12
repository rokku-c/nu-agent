#!/usr/bin/env nu
# install.nu — wire this checkout into a nushell config
#
#   nu install.nu                 # install into the running config
#   nu install.nu --check         # verify only, write nothing
#   nu install.nu --uninstall     # remove exactly what was written
#   nu install.nu --config <path> # target a specific config.nu (used by the tests)
#
# ── what it writes, and where ──
# ONE marker-guarded block appended to config.nu, nothing else. Every line in it
# is an ABSOLUTE path, and that is deliberate: see the note below.
#
# ── why absolute paths and not NU_LIB_DIRS ──
# two traps, both measured:
#
#  · NU_LIB_DIRS looks like the natural mechanism and is a trap. nu strips its own
#    NU_LIB_DIRS entry from the environment it hands to child processes — visible
#    in-process, absent in a `^nu` child. Every tool call runs in such a child
#    (`invoke-tool` spawns `^nu --config $nu.config-path`), so a lib-dir-based
#    install would resolve fine at the prompt and fail on every single tool call.
#
#  · `$env.NU_AGENT_ROOT | path join …` cannot be used in a `use` line at all: an
#    env var is not a parse-time constant, and `use` is resolved at parse time.
#    Neither can `$env.FILE_PWD`. `$nu.default-config-dir` is a constant, but it
#    is the *platform default* directory regardless of `--config`, so it only
#    works when the files actually live there.
#
# an absolute path has no such failure mode: the child re-reads this same
# config.nu and gets the same answer, at any process depth (verified through
# parent → child → grandchild). Module-to-module imports inside the repo need
# nothing at all — a relative `use` resolves against the containing file.
#
# moving or renaming the checkout therefore means re-running this installer.
# that is the honest cost of the above, and `--check` will tell you when it drifts.

const BEGIN = "# ── nu-agent (begin) ── written by install.nu; edits inside are overwritten ──"
const END = "# ── nu-agent (end) ──"

# capability modules first (they become the MCP tools), then the runtime
const TOOL_MODULES = ["bash" "calc" "host" "image" "jsonschema" "nu-shell" "peers" "read" "remote" "toon" "write"]
# task is a capability (the model calls it), but it is not in tools/ — it is a
# wrapper around the loop, and belongs beside it
const CORE_MODULES = ["agent" "context" "expose" "markdown" "mcp" "policy" "session" "style" "task" "trace"]

def root []: nothing -> path {
  # a SCRIPT (unlike a module body) does see $env.FILE_PWD at eval time — measured.
  $env.FILE_PWD | path expand
}

def target-config [override: any]: nothing -> path {
  if $override == null {
    $nu.config-path | path expand
  } else {
    $override | path expand
  }
}

def block [r: path]: nothing -> string {
  let lines = (
    [$"$env.NU_AGENT_ROOT = \"($r)\""]
    | append ($TOOL_MODULES | each {|m| $"use ($r)/tools/($m).nu" })
    | append ($CORE_MODULES | each {|m| $"use ($r)/core/($m).nu" })
  )
  ([$BEGIN] | append $lines | append [$END]) | str join (char nl)
}

# everything before BEGIN, everything after END, and the block rebuilt in between
def splice [text: string, r: path]: nothing -> string {
  let lines = ($text | lines)
  let bi = ($lines | enumerate | where {|x| ($x.item | str trim) == $BEGIN } | get --optional index | first)
  let ei = ($lines | enumerate | where {|x| ($x.item | str trim) == $END } | get --optional index | first)

  if $bi == null or $ei == null or $ei < $bi {
    # not installed yet (or only half of a pair) — append a fresh block
    let head = ($text | str trim -r -c (char nl))
    return $"($head)(char nl)(char nl)(char nl)(block $r)(char nl)"
  }

  let before = ($lines | first $bi)
  let after = ($lines | skip ($ei + 1))
  ($before | append [(block $r)] | append $after) | str join (char nl) | str trim -r -c (char nl) | $in + (char nl)
}

def strip-block [text: string]: nothing -> string {
  let lines = ($text | lines)
  let bi = ($lines | enumerate | where {|x| ($x.item | str trim) == $BEGIN } | get --optional index | first)
  let ei = ($lines | enumerate | where {|x| ($x.item | str trim) == $END } | get --optional index | first)
  if $bi == null or $ei == null { return $text }
  ($lines | first $bi | append ($lines | skip ($ei + 1)))
  | str join (char nl) | str trim -r -c (char nl) | $in + (char nl)
}

def mcp-snippet [r: path, cfg: path]: nothing -> string {
  {
    mcpServers: {
      agent: {
        type: "stdio"
        command: "nu"
        args: ["--config", ($cfg | into string), $"($r)/core/mcp-server.nu"]
        env: {NU_MCP_MODULES: "*"}
      }
    }
  } | to json -r
}

def main [
  --config: path      # config.nu to write to; defaults to the running one
  --check             # report what would happen, change nothing
  --uninstall         # remove the block instead of writing it
]: nothing -> nothing {
  let r = (root)
  let cfg = (target-config $config)

  if not ($cfg | path exists) {
    error make { msg: $"config file not found: ($cfg)" }
  }

  # sanity: the modules we are about to point at must actually be there
  let missing = (
    ($TOOL_MODULES | each {|m| $"($r)/tools/($m).nu" })
    | append ($CORE_MODULES | each {|m| $"($r)/core/($m).nu" })
    | where {|p| not ($p | path exists) }
  )
  if ($missing | is-not-empty) {
    error make { msg: $"these module files are missing — is install.nu being run from the repo root?\n  ($missing | str join (char nl + '  '))" }
  }

  let text = (open --raw $cfg)
  let already = (($text | lines) | any {|l| ($l | str trim) == $BEGIN })

  if $uninstall {
    let out = (strip-block $text)
    if $out == $text {
      print "nothing to remove — no nu-agent block in this config"
      return
    }
    if $check {
      print $"── would remove the nu-agent block from ($cfg) ──"
      return
    }
    $out | save -f $cfg
    print $"removed the nu-agent block from ($cfg). reopen nu for it to take effect."
    return
  }

  print $"repo    : ($r)"
  print $"config  : ($cfg)"
  print $"modules : ($TOOL_MODULES | length) capabilities + ($CORE_MODULES | length) runtime"
  print $"state   : (if $already { 'already installed — block will be replaced in place' } else { 'not installed yet — block will be appended' })"
  print ""

  if $check {
    print "── block that would be written ──"
    print (block $r)
    print ""
    print "── MCP server entry (paste into your MCP client config) ──"
    print (mcp-snippet $r $cfg)
    print ""

    # verify against the config as it WOULD be, not as it is — otherwise a fresh
    # install always reports 0 modules, which reads like a failure and is useless
    # as a pre-flight. write the spliced result to a temp file and run the child
    # against that, so the exact thing about to be installed is what gets tested.
    print "── verifying resolution in a CHILD process (the tool-call path) ──"
    let probe_cfg = ($nu.temp-dir | path join "nu-agent-check-config.nu")
    (splice $text $r) | save -f $probe_cfg
    let probe = (^nu --config $probe_cfg -c 'scope modules | where {|m| $m.name !~ "^prelude" } | get name | to json -r' | complete)
    rm -f $probe_cfg
    if $probe.exit_code != 0 {
      print $"  ✗ child could not load the modules:\n($probe.stderr | str trim)"
      error make { msg: "the block that would be installed does not resolve in a child process — not writing it" }
    }
    let loaded = ($probe.stdout | str trim | from json)
    if ($loaded | is-empty) {
      error make { msg: "the child process loaded zero modules — the block that would be installed is broken" }
    }
    print $"  ✓ child loaded ($loaded | length) modules: ($loaded | to json -r)"
    print ""
    print "  (nothing was written; drop --check to install)"
    return
  }

  (splice $text $r) | save -f $cfg
  print "installed. the block is marker-guarded, so re-running replaces it instead of stacking."
  print ""
  print "next:"
  print "  1. reopen nu (config.nu is only read at startup)"
  print "  2. check it:  nu install.nu --check"
  print "  3. MCP client entry:"
  print $"     (mcp-snippet $r $cfg)"
}
