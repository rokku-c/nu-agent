# harness.nu — the assertion helpers the test files share
#
# ── output contract ──
# results go to the file in $env.NU_TEST_REPORT when the runner set it, and to
# stdout otherwise (so a suite is still runnable by hand).
#
# a file, not stdout — and that is not fussiness. a suite's own output can land
# on stdout: the `--stream` case legitimately prints the model's text there, and
# that turned the result JSON into `1, 2, 3\n[{…}]`, which the runner could not
# parse. the same "stdout is data" rule the modules follow has to apply to the
# test harness too. progress lines go to stderr either way.

use ../core/reason.nu

# one assertion: got must equal want
export def eq [name: string, got: any, want: any]: nothing -> record {
  let ok = ($got == $want)
  {name: $name, ok: $ok, detail: (if $ok { "" } else { $"got ($got | to json -r), want ($want | to json -r)" })}
}

# got must be true
export def is-true [name: string, got: any]: nothing -> record {
  let ok = ($got == true)
  {name: $name, ok: $ok, detail: (if $ok { "" } else { $"got ($got | to json -r), want true" })}
}

# hay must contain needle
export def has [name: string, hay: any, needle: string]: nothing -> record {
  let s = ($hay | into string)
  let ok = ($s | str contains $needle)
  {name: $name, ok: $ok, detail: (if $ok { "" } else { $"($needle | to json -r) not found in ($s | str substring 0..200)" })}
}

# hay must NOT contain needle
export def lacks [name: string, hay: any, needle: string]: nothing -> record {
  let s = ($hay | into string)
  let ok = (not ($s | str contains $needle))
  {name: $name, ok: $ok, detail: (if $ok { "" } else { $"($needle | to json -r) should not appear in ($s | str substring 0..200)" })}
}

# the closure must raise
export def throws [name: string, f: closure]: nothing -> record {
  let threw = (try { do $f; false } catch { true })
  {name: $name, ok: $threw, detail: (if $threw { "" } else { "expected an error, none was raised" })}
}

# run a case. a case is a closure returning one result record; if it crashes
# instead, that becomes a failed result rather than taking the whole file down.
export def case [name: string, f: closure]: nothing -> record {
  try {
    do $f
  } catch {|e|
    {name: $name, ok: false, detail: ($"crashed: (reason $e)" | str substring 0..300)}
  }
}

# a case that needs credentials, skipped when they are absent.
export def needs-creds []: nothing -> bool {
  let t = ($env.ANTHROPIC_AUTH_TOKEN? | default "")
  ($t | is-not-empty)
}

# a skipped case. NOT a failure — the point is that it is neither a silent pass
# nor a spurious failure: a suite that cannot run here must still say so, without
# turning a credential-less checkout red.
#
# named `skipped`, not `skip`: `skip` is a nushell builtin (`$list | skip 2`), and
# a suite imports this with `use ./harness.nu *` — a glob import that shadows the
# builtin for every module parsed afterwards. that is not hypothetical: it broke
# `session window` the moment a suite imported session.nu after the harness.
export def skipped [name: string, reason: string]: nothing -> record {
  {name: $name, ok: true, skipped: true, detail: $reason}
}

# print ✓/✗ to stderr, put the results where the runner can find them
export def emit [results: list]: nothing -> any {
  for r in $results {
    if ($r | get --optional skipped | default false) {
      print -e $"  ○ ($r.name) — skipped: ($r | get --optional detail | default '')"
    } else if ($r | get --optional ok | default false) {
      print -e $"  ✓ ($r.name)"
    } else {
      print -e $"  ✗ ($r.name) — ($r | get --optional detail | default '')"
    }
  }
  let json = ($results | to json -r)
  let dest = ($env.NU_TEST_REPORT? | default "")
  if ($dest | is-empty) {
    $json
  } else {
    $json | save -f $dest
    null
  }
}
