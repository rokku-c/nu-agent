# shells.nu — which shells this machine offers, and which one is the default (internal)
#
# Shared by the `shell` tool and the interactive mode's `/shell`, and hidden for
# the same reason core/fileio.nu is: an exported helper in tools/shell.nu becomes
# a tool. It did, for a while — `shell_available` and `shell_resolve` showed up in
# the MCP tool list, which is the trap this file's sibling was created to avoid.
# The allowlist is per module, so anything public in a capability module is lent
# to the model.

# bash, NOT $SHELL. on this machine SHELL is fish, and a model writing bash idioms
# into fish gets a screenful of syntax errors for its trouble. the shell is
# something the caller chooses, not something inherited from whatever launched
# the agent.
export const DEFAULT_SHELL = "/bin/bash"

# the shells this machine offers, from /etc/shells — the file that exists for
# exactly this question, and the one chsh reads
export def available []: nothing -> list<string> {
  let f = "/etc/shells"
  if not ($f | path exists) { return [$DEFAULT_SHELL] }
  open --raw $f
  | lines
  | each {|l| $l | str trim }
  | where {|l| ($l | is-not-empty) and (not ($l | str starts-with "#")) and ($l | path exists) }
}

# the shell a call runs through, most specific first: the flag on this call, then
# $env.NU_AGENT_SHELL, then bash.
export def resolve [flag: any]: nothing -> string {
  let wanted = (
    if $flag != null and ($flag | is-not-empty) { $flag }
    else if (($env.NU_AGENT_SHELL? | default "") | is-not-empty) { $env.NU_AGENT_SHELL }
    else { return $DEFAULT_SHELL }
  )

  # a path, or just the name of one. `--shell fish` is what a caller will type;
  # `path exists "fish"` is a question about the current directory, and answers
  # no. so a bare name is matched against what this machine actually has.
  if ($wanted | path exists) { return $wanted }
  let hits = (available | where {|p| ($p | path basename) == $wanted })
  if ($hits | is-empty) {
    let names = (available | each {|p| $p | path basename } | str join ", ")
    error make { msg: $"no such shell: ($wanted). this machine has: ($names)" }
  }
  $hits.0
}
