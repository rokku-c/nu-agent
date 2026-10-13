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
#   shell --list                     # which shells this machine has, and which is the default
#   shell "echo $FISH_VERSION" --shell fish   # one call through another shell
#
# the default shell is /bin/bash; $env.NU_AGENT_SHELL overrides it for every
# call, --shell for one. bash is NOT a fallback for $SHELL: on a machine whose
# login shell is fish, following $SHELL would make every bash idiom the model
# writes fail.
#
# local runs go through /bin/bash (macOS ships 3.2.57 — no associative arrays, no
# ** recursive globbing; for a newer one install bash 5 yourself and fix PATH).
# remote runs always use the far end's `sh -c`, immune to its login shell (some boxes are csh).
#
# timeout: local is done with job spawn + job kill, taking child processes down too.
# remote only covers the ssh connect phase — once connected, a hung command still needs Ctrl-C.

use ./host.nu

const DEFAULT_MAX_OUTPUT = 8000

# ── which shell ──
# bash, NOT $SHELL. on this machine SHELL is fish, and a model writing bash
# idioms into fish gets a screenful of syntax errors for its trouble. the shell
# is something the caller chooses, not something inherited from the environment
# the agent happens to be launched in.
const DEFAULT_SHELL = "/bin/bash"

# the shells this machine offers, from /etc/shells — which is the file that
# exists for exactly this question, and is what chsh reads.
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
  let chosen = (
    if $flag != null and ($flag | is-not-empty) { $flag }
    else if (($env.NU_AGENT_SHELL? | default "") | is-not-empty) { $env.NU_AGENT_SHELL }
    else { $DEFAULT_SHELL }
  )
  if not ($chosen | path exists) {
    error make { msg: $"no such shell: ($chosen). see what this machine has with `shell --list`" }
  }
  $chosen
}

def clamp [s: string, n: int]: nothing -> string {
  if ($s | str length) > $n {
    # literal parens are written \( \) — a bare ( is taken as an interpolation and runs a command
    $"($s | str substring 0..$n)\n...\(output truncated, was ($s | str length) chars\)"
  } else {
    $s
  }
}

def local-exec [command: string, sh: string, cwd: any, stdin: any, timeout: any]: nothing -> record {
  let body = {
    do {
      # cd only affects this block, it doesn't pollute the caller's current directory
      if $cwd != null { cd $cwd }
      if $stdin != null {
        $stdin | run-external $sh "-c" $command | complete
      } else {
        run-external $sh "-c" $command | complete
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
  command?: string                         # the command to run; omitted with --list
  --shell (-b): string                     # which shell runs it; default $env.NU_AGENT_SHELL, else /bin/bash
  --list (-l)                              # list the shells this machine offers, marking the default
  --cwd (-c): path                         # working directory, defaults to the current one
  --stdin: string                          # stdin to feed the command
  --max-output: int = $DEFAULT_MAX_OUTPUT  # truncate output past this length
  --json (-j)                              # return {exit_code, stdout, stderr}
  --host: string                           # run on a registered remote host
  --timeout (-t): duration                 # timeout (local only; remote covers the connect phase)
]: nothing -> any {
  # --list answers "what can I switch to", which is why the command is optional
  if $list {
    let now = (resolve $shell)
    return (available | each {|p| {shell: $p, default: ($p == $now)} })
  }
  if $command == null {
    error make { msg: "give a command to run, or --list to see the shells this machine offers" }
  }

  let sh = (resolve $shell)

  # remote runs always go through `sh -c` on the far end — see wrap in host.nu.
  # --shell is a local choice; a remote's shells are the remote's business.
  let r = (
    if $host != null {
      host exec $host $command --stdin $stdin --cwd $cwd
    } else {
      local-exec $command $sh $cwd $stdin $timeout
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
    let label = (if $host == null { $"shell($sh | path basename)" } else { $"shell @ ($host)" })
    let extra = (if ($out | is-empty) { "" } else { $"\nstdout:\n($out)" })
    error make { msg: (clamp $"($label) exit code ($r.exit_code)\nstderr:\n($err)($extra)" $max_output) }
  }

  clamp $out $max_output
}
