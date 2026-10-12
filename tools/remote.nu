# remote.nu — run nushell code on a remote host/container
#
#   use remote.nu
#   remote prod "uname -a"
#   remote prod "ls | where size > 1mb | to json" --json
#   remote prod "use read.nu *; read /etc/hosts --limit 3"
#   remote prod "ls | length" --json
#
# this is the explicit "full capability" channel: the basic tools (read/write/bash)
# go pure POSIX, so any machine you can ssh to works; use this to run nu pipelines remotely,
# at the cost of installing nushell there. Pair with `host sync` to push local modules over.
#
# a remote without nu errors clearly, instead of a baffling command not found.
#
# note: the code is embedded in the remote command line (a remote nu can't read commands
# from stdin — `nu -c -` just takes `-` as the command string), so it's protected by sh-quote.

use ./host.nu

const DEFAULT_DIR = "~/.nu-modules"

# ~ can't be sh-quoted directly (no expansion inside single quotes), so ask the remote for $HOME
def expand-remote [host: string, dir: string]: nothing -> string {
  if not ($dir | str starts-with "~") { return $dir }
  let r = (host exec $host "printf '%s' \"$HOME\"")
  if $r.exit_code != 0 {
    error make { msg: $"can't get the remote HOME: ($r.stderr | str trim)" }
  }
  let home = ($r.stdout | str trim)
  $dir | str replace "~" $home
}

export def main [
  host: string                    # a registered host
  code: string                    # nushell code to run remotely
  --json (-j)                     # to json the remote result, from json locally
  --dir: string = $DEFAULT_DIR    # remote module directory, set as NU_LIB_DIRS
  --no-lib-dir                    # don't set NU_LIB_DIRS, use the remote's default environment
]: nothing -> any {
  # confirm the remote has nu first, else later errors are very hard to make sense of
  let probe = (host exec $host "command -v nu")
  if $probe.exit_code != 0 {
    error make { msg: $"no nushell on ($host). once installed, push the modules over with host sync" }
  }

  # wrap multi-statement code in do { } so the --json | to json append binds correctly
  let body = (if $json { $"do { ($code) } | to json" } else { $code })

  let nu_cmd = (
    if $no_lib_dir {
      $"nu --commands (quote sh $body)"
    } else {
      let dir = (expand-remote $host $dir)
      $"env NU_LIB_DIRS=(quote sh $dir) nu --commands (quote sh $body)"
    }
  )

  let r = (host exec $host $nu_cmd)
  if $r.exit_code != 0 {
    error make { msg: $"remote nu execution failed: ($r.stderr | str trim)" }
  }

  let out = ($r.stdout | str trim -r -c (char nl))
  if not $json { return $out }

  if ($out | is-empty) {
    error make { msg: "remote result is empty, --json expects it to print JSON" }
  }
  $out | from json
}
