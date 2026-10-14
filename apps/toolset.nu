# toolset.nu — search, load and unload what the agent can do
#
#   use toolset.nu
#
#   toolset available                       # every capability module, with its tools
#   toolset search market                   # which modules offer something called that
#   toolset load host remote                # add them to the active set
#   toolset unload host                     # take them back out
#   toolset show                            # what is active now
#
# ── the two names, which are not the same ──
# a MODULE is what `--tools-from` takes (`proc`, `shell`). a TOOL is what the model calls
# (`exec`, `shell`). they coincide for most modules and diverge for exactly the interesting
# ones — `expose from-module proc` yields a tool named `exec`. so `load` and `unload` speak
# module names while `available` and `search` report both, because a person looking for
# "exec" needs to be told it lives in `proc`.
#
# ── why the set is a file rather than an argument ──
# a tool set that can only be changed by restarting the thing that uses it is not manageable,
# it is configured. the bridge re-reads this on every poll, so `load` and `unload` take effect
# on the next message rather than at the next restart.
#
# ── what "available" means, and its one lie ──
# it is derived from the modules actually loaded in this process — not from a list in a file —
# so it cannot drift from reality. the lie is that a module has to be `use`d in the config to
# appear at all: `install.nu` decides that set, and something installed but not loaded is
# invisible here rather than shown as unavailable.

const DIR_NAME = "nu-agent-toolsets"
const SET_NAME = "active"

# never offered as a capability: these are the runtime, not things the model should be handed.
# `agent` above all — a tool that could call it lets the model recursively spawn the loop.
const RUNTIME = [
  "agent" "context" "expose" "markdown" "mcp" "policy" "style" "task" "trace"
  "session" "handoff" "interactive" "toolset" "quote" "layout" "prelude" "nu-agents"
]

def store-dir []: nothing -> path {
  let override = ($env.NU_AGENT_TOOLSET_DIR? | default "")
  if ($override | is-empty) { $nu.data-dir | path join $DIR_NAME } else { $override | path expand }
}

def set-path [name: string]: nothing -> path { store-dir | path join $"($name).json" }

# every module that can be handed to the model: loaded in this process, yields at least one
# tool, and is not runtime machinery. the descriptions come from each command's own doc
# comment — the same text the model will read — so search matches what the model will see.
#
# it goes through a CHILD PROCESS, and that is not incidental. measured: `scope modules`
# inside a function defined in an imported module sees ZERO modules, while the same def
# written in a script file sees all of them — the module set is only visible to top-level
# code in the process that loaded it. mcp-server.nu hit this first and solves it the same
# way. the child re-reads the config, so it sees what the config actually loaded.
export def available []: nothing -> any {
  # single-quoted and concatenated: inside $"..." the child's `$m` and `$e` would be read as
  # this process's variables, which is the trap mcp-server.nu's comment warns about.
  let runtime = ($RUNTIME | to nuon)
  let body = 'scope modules | where {|m| ($m.name !~ "^prelude") and not ($m.name in ' + $runtime + ') } | get name | each {|m| let t = (try { expose from-module $m } catch { [] }); if ($t | is-empty) { null } else { {module: $m, tools: ($t | get name), about: ($t | first | get description | str replace -r "\n.*" "")} } } | compact | sort-by module | to json -r'
  let r = (^nu --config $nu.config-path -c $body | complete)
  if $r.exit_code != 0 {
    error make { msg: $"could not list modules: ($r.stderr | str trim | str substring 0..300)" }
  }
  let out = ($r.stdout | str trim)
  if ($out | is-empty) { return [] }
  $out | from json
}

# find something by module name, tool name, or the words in a tool's description — because
# "which module gives me exec" and "what can edit files" are the same kind of question and
# only one of them knows the module name.
export def search [query: string]: nothing -> any {
  let q = ($query | str lowercase)
  # `or` must stay on the same line as its left operand: starting a line with it makes
  # nushell run it as an external command. the same trap as `and` elsewhere, and expose.nu
  # documents it for exactly this reason.
  available | where {|m| ($m.module | str lowercase | str contains $q) or ((($m.tools | str join " ") | str lowercase | str contains $q) or ($m.about | str lowercase | str contains $q)) }
}

# the active set, or the built-in default when nothing has been written yet
export def show []: nothing -> record {
  let p = (set-path $SET_NAME)
  let modules = (if ($p | path exists) { open $p | get modules } else { default-set })
  {
    modules: $modules
    stored_at: (if ($p | path exists) { ($p | into string) } else { null })
    note: (if ($p | path exists) { "read from the set file" } else { "the built-in default — nothing has been saved yet" })
  }
}

def default-set []: nothing -> list<string> {
  ["nu-shell" "shell" "proc" "read" "write" "edit" "calc"
   "market" "macro" "series" "daily" "pred"]
}

def save-set [modules: list<string>]: nothing -> record {
  mkdir (store-dir)
  {modules: $modules, updated_at: (date now | format date "%Y-%m-%dT%H:%M:%S")}
  | save -f --force (set-path $SET_NAME)
  {modules: $modules, stored_at: ((set-path $SET_NAME) | into string)}
}

# add modules to the active set. a module that yields no tools is refused rather than
# silently added — an empty entry in the list looks like a working capability and is not one.
export def load [...modules: string]: nothing -> any {
  if ($modules | is-empty) { error make { msg: "name at least one module" } }
  let known = (available | get module)
  let bad = ($modules | where {|m| not ($m in $known) })
  if ($bad | is-not-empty) {
    error make { msg: $"no such module\(s\): ($bad | str join ', '). `toolset search` lists what is loaded — a module that exists but is not `use`d in the config will not appear" }
  }
  let cur = (show | get modules)
  let next = ($cur | append $modules | uniq)
  save-set $next | insert added ($next | where {|m| not ($m in $cur) }) | insert unchanged ($modules | where {|m| $m in $cur })
}

# remove modules from the active set
export def unload [...modules: string]: nothing -> any {
  if ($modules | is-empty) { error make { msg: "name at least one module" } }
  let cur = (show | get modules)
  let gone = ($modules | where {|m| $m in $cur })
  save-set ($cur | where {|m| not ($m in $modules)}) | insert removed $gone
}

# back to the built-in default, and delete the override
export def reset []: nothing -> any {
  let p = (set-path $SET_NAME)
  if ($p | path exists) { rm -f $p }
  {modules: (default-set), cleared: (($p | into string))}
}

# the tool names the active set actually yields — what the model will see, not what the
# modules are called.
#
# it reads from `available` rather than calling `expose` itself, and that is not a
# micro-optimisation: `expose` inside a closure in an imported module sees no modules, so the
# direct version returned an empty list and looked like "this tool set has no tools". one
# child process, once, is the whole reason this works.
export def tools []: nothing -> list<string> {
  let act = (show | get modules)
  available | where {|m| $m.module in $act } | get tools | flatten
}
