# proc.nu — run a program directly, with no shell in between
#
# ── why it is called proc, not exec ──
# nu cannot have a command named `exec`: it is a parser keyword, and keywords
# cannot be shadowed ("Parser keywords cannot be shadowed"). `run` is taken the
# same way. so the FILE and the COMMAND are `proc`, and the tool a model is
# offered is `proc` too, because the tool name is derived from the module name.
#
# giving it the tool name `exec` needs a rename where commands become tools —
# in core/expose.nu — and the attempt at that did not take effect. it is a small,
# self-contained piece of work; until it lands, call it `proc`.
#
#   use proc.nu
#   exec "git" ["status" "--short"]
#   exec "rg" ["--json" "needle"] --cwd ~/proj
#   exec "cat" [] --stdin "content to feed in"
#   exec "false" [] --json          # {exit_code, stdout, stderr}
#
# ── why this exists next to `shell` ──
# `shell` hands a command LINE to a shell, which is what you want for pipes,
# globs, redirection and variable expansion. `exec` hands a program and its argv
# straight to the OS. that difference is not cosmetic:
#
#   shell "grep foo *.txt | wc -l"     a shell parses this
#   exec "grep" ["foo" "a.txt"]        nothing parses this
#
# so an argument can never be re-split or re-interpreted. a filename containing a
# space, a semicolon or `$(…)` is a filename and nothing else, and there is no
# quoting layer to get wrong. for anything that is not a pipeline, this is the
# better call.
#
# the trade is symmetric: no globs, no pipes, no `~`, no variable expansion. if
# you need any of those, use `shell`.
#
# local only. a remote's argv would have to travel through the far end's shell to
# get there — `host exec` wraps everything in `sh -c` — which would put back
# exactly the parsing this tool exists to avoid. use `shell --host` for that.

const DEFAULT_MAX_OUTPUT = 8000

def clamp [s: string, n: int]: nothing -> string {
  if ($s | str length) > $n {
    # literal parens are written \( \) — a bare ( is taken as an interpolation and runs a command
    $"($s | str substring 0..$n)\n...\(output truncated, was ($s | str length) chars\)"
  } else {
    $s
  }
}

def invoke [program: string, args: list<string>, cwd: any, stdin: any, timeout: any]: nothing -> record {
  let body = {
    do {
      if $cwd != null { cd $cwd }
      # run-external with argv: no shell anywhere in the chain
      if $stdin != null {
        $stdin | run-external $program ...$args | complete
      } else {
        run-external $program ...$args | complete
      }
    }
  }

  if $timeout == null { return (do $body) }

  let id = (job spawn { do $body | job send 0 })
  try {
    job recv --timeout $timeout
  } catch {
    job kill $id
    error make { msg: $"($program) ran past ($timeout) without finishing, killed" }
  }
}

# run one program and return its stdout.
# throws on a non-zero exit code (stderr included in the error), so an agent loop
# can mark it is_error.
export def main [
  program: string                          # the program to run, e.g. "git"
  args: list<string> = []                  # its arguments, passed through untouched
  --cwd (-c): path                         # working directory, defaults to the current one
  --stdin: string                          # stdin to feed the program
  --max-output: int = $DEFAULT_MAX_OUTPUT  # truncate output past this length
  --json (-j)                              # return {exit_code, stdout, stderr}
  --timeout (-t): duration                 # killed at the deadline, children included
]: nothing -> any {
  # an external command that does not exist is a nu error before it is a shell
  # error; say which, because "command not found" from a tool that never had a
  # shell is confusing
  if (which $program | is-empty) {
    error make { msg: $"no such program: ($program). exec does not use a shell, so this is a path lookup, not a shell builtin or alias" }
  }

  let r = (invoke $program $args $cwd $stdin $timeout)

  let out = ($r.stdout | str trim -r -c (char nl))
  let err = ($r.stderr | str trim -r -c (char nl))

  if $json {
    return {exit_code: $r.exit_code, stdout: (clamp $out $max_output), stderr: (clamp $err $max_output)}
  }

  if $r.exit_code != 0 {
    let extra = (if ($out | is-empty) { "" } else { $"\nstdout:\n($out)" })
    error make { msg: (clamp $"($program) exit code ($r.exit_code)\nstderr:\n($err)($extra)" $max_output) }
  }

  clamp $out $max_output
}
