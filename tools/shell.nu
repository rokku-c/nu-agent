# shell.nu — run shell commands (local or remote)
#
# named `shell`, not `bash`: what the agent is asking for is "run a shell
# command", and `bash` names the implementation. the pair is now `shell` (a
# POSIX-ish shell) and `nu-shell` (nushell), which is what a model has to choose
# between. the implementation is still /bin/bash -c, and says so below.
#
#   use shell.nu
#   shell "ls -la"
#   shell "make test" --cwd ~/proj
#   shell "cat" --stdin "content to feed in"
#   shell "exit 3" --json            # get {exit_code, stdout, stderr}
#   shell "uname -a" --host prod     # remote (register first with host)
#   shell "make test" --timeout 5min # local timeout, killed at the deadline
#
# local runs go through /bin/bash (macOS ships 3.2.57 — no associative arrays, no
# ** recursive globbing; for a newer one install bash 5 yourself and fix PATH).
# remote runs always use the far end's `sh -c`, immune to its login shell (some boxes are csh).
#
# timeout: local is done with job spawn + job kill, taking child processes down too.
# remote only covers the ssh connect phase — once connected, a hung command still needs Ctrl-C.

use ./host.nu

const DEFAULT_MAX_OUTPUT = 8000

def clamp [s: string, n: int]: nothing -> string {
  if ($s | str length) > $n {
    # literal parens are written \( \) — a bare ( is taken as an interpolation and runs a command
    $"($s | str substring 0..$n)\n...\(output truncated, was ($s | str length) chars\)"
  } else {
    $s
  }
}

def local-exec [command: string, cwd: any, stdin: any, timeout: any]: nothing -> record {
  let body = {
    do {
      # cd only affects this block, it doesn't pollute the caller's current directory
      if $cwd != null { cd $cwd }
      if $stdin != null {
        $stdin | ^bash -c $command | complete
      } else {
        ^bash -c $command | complete
      }
    }
  }

  if $timeout == null {
    return (do $body)
  }

  # timeout: run in a background job; the parent waits for the result, kills it if it's late.
  # job kill takes the child processes with it (pgrep is 0 after the kill in testing)
  let id = (job spawn { do $body | job send 0 })
  try {
    job recv --timeout $timeout
  } catch {
    job kill $id
    error make { msg: $"command ran past ($timeout) without finishing, killed" }
  }
}

# run one command and return its stdout.
# throws on a non-zero exit code (stderr included in the error), so an agent loop can mark it is_error.
export def main [
  command: string                          # the command to run
  --cwd (-c): path                         # working directory, defaults to the current one
  --stdin: string                          # stdin to feed the command
  --max-output: int = $DEFAULT_MAX_OUTPUT  # truncate output past this length
  --json (-j)                              # return {exit_code, stdout, stderr}
  --host: string                           # run on a registered remote host
  --timeout (-t): duration                 # timeout (local only; remote covers the connect phase)
]: nothing -> any {
  let r = (
    if $host != null {
      host exec $host $command --stdin $stdin --cwd $cwd
    } else {
      local-exec $command $cwd $stdin $timeout
    }
  )

  # strip only the trailing newline, whitespace inside lines is kept
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
    let label = (if $host == null { "shell" } else { $"shell @ ($host)" })
    let extra = (if ($out | is-empty) { "" } else { $"\nstdout:\n($out)" })
    error make { msg: (clamp $"($label) exit code ($r.exit_code)\nstderr:\n($err)($extra)" $max_output) }
  }

  clamp $out $max_output
}
