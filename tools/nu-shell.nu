# nu-shell.nu — run nushell code directly (local or remote)
#
#   use nu-shell.nu
#   nu-shell "ls | where size > 1mb | length"
#   nu-shell "calc '2+2'; read /etc/hosts --limit 2"
#   nu-shell "host list"
#   nu-shell "open data.json | jsonschema infer" --json
#   nu-shell "uname -a" --host prod
#
# division of labour with bash:
#   bash  → runs shell commands (bash)
#   nu-shell → runs nu code, so every registered module is usable directly
#              (calc / read / write / host / jsonschema …)
#
# the local path spawns `nu --config <your config> --commands <code>`,
# so every module used in config.nu is present.
# with --host it delegates to remote (needs nu installed remotely and modules synced
# with host sync); on that path exit_code is always 0 — a failure throws rather than being silent.

use ./host.nu
use ./remote.nu

const DEFAULT_MAX_OUTPUT = 8000

def clamp [s: string, n: int]: nothing -> string {
  if ($s | str length) > $n {
    # literal parens are written \( \) — a bare ( is taken as an interpolation and runs a command
    $"($s | str substring 0..$n)\n...\(output truncated, was ($s | str length) chars\)"
  } else {
    $s
  }
}

def local-exec [code: string, cwd: any, timeout: any]: nothing -> record {
  # argv passed straight through, no shell involved — the code goes to nu as-is, no escaping
  let argv = ["nu", "--config", ($nu.config-path | into string), "--commands", $code]
  let cmd = ($argv | first)
  let args = ($argv | skip 1)

  let body = {
    do {
      if $cwd != null { cd $cwd }
      run-external $cmd ...$args | complete
    }
  }

  if $timeout == null {
    return (do $body)
  }

  # timeout: hand it to a background job, kill it when the deadline passes with no result (children go too)
  let id = (job spawn { do $body | job send 0 })
  try {
    job recv --timeout $timeout
  } catch {
    job kill $id
    error make { msg: $"nu code ran past ($timeout) without finishing, killed" }
  }
}

# run a piece of nushell code and return its stdout.
# throws on a non-zero exit code, so an agent loop can mark it is_error.
export def main [
  code: string                             # nushell code to run
  --cwd (-c): path                         # working directory
  --json (-j)                              # return {exit_code, stdout, stderr}
  --max-output: int = $DEFAULT_MAX_OUTPUT  # truncate output past this length
  --timeout (-t): duration                 # timeout (local only)
  --host: string                           # run on a registered remote host
]: nothing -> any {
  if $host != null {
    # a remote missing nu makes remote error clearly; it throws on failure, so reaching here means success
    let out = (remote $host $code)
    if $json {
      return {exit_code: 0, stdout: (clamp $out $max_output), stderr: ""}
    }
    return (clamp $out $max_output)
  }

  let r = (local-exec $code $cwd $timeout)
  let out = ($r.stdout | str trim -r -c (char nl))
  let err = ($r.stderr | str trim -r -c (char nl))

  if $json {
    return {
      exit_code: $r.exit_code
      stdout: (clamp $out $max_output)
      stderr: (clamp $err $max_output)
    }
  }

  if $r.exit_code != 0 {
    let extra = (if ($out | is-empty) { "" } else { $"\nstdout:\n($out)" })
    error make { msg: (clamp $"nu exit code ($r.exit_code)\nstderr:\n($err)($extra)" $max_output) }
  }

  clamp $out $max_output
}
