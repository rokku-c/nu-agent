# layout.nu — where this checkout lives, at RUNTIME (internal helper)
#
# ── why this exists at all ──
# Module *resolution* needs nothing from here. `use` is resolved at parse time,
# and both forms used in this repo work inside a child process: the entry lines
# in config.nu are absolute (install.nu writes them), and module-to-module
# imports are relative to the containing file (measured — a relative `use`
# resolves against the file's own directory, not the cwd).
#
# But two things are read at *runtime* rather than parse time:
#   · the trace HTML template (`trace write`)
#   · the set of module files `host sync` pushes to a remote
# and a module cannot learn its own directory then: `$env.FILE_PWD` is empty
# inside a command body (measured), and it is not a parse-time constant either,
# so it cannot be captured into a `const` either.
#
# So config.nu carries the path in `NU_AGENT_ROOT`. A child process re-reads
# config.nu, so it inherits the value — verified through two process levels.
#
# ── why not NU_LIB_DIRS ──
# it looks like the natural answer and it is a trap: nu strips its own
# NU_LIB_DIRS entry from the environment it hands to child processes (measured:
# visible in-process as `[/tmp/w, …/scripts, …/completions]`, absent in a `^nu`
# child). Every tool call here runs in such a child, so anything resolved
# through NU_LIB_DIRS works in the top-level session and fails on every single
# tool call.

export def root []: nothing -> path {
  let r = ($env.NU_AGENT_ROOT? | default "")
  if ($r | is-empty) {
    error make { msg: "NU_AGENT_ROOT is unset, so the checkout location is unknown. install.nu writes it into config.nu; set it by hand if you load the modules directly." }
  }
  $r | path expand
}
