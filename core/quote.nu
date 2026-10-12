# quote.nu — POSIX single-quote escaping (internal helper)
#
# data only, never the command itself — see the quoting model in tools/host.nu.
# exported because host.nu and remote.nu both build remote command strings from
# data (paths, container names, embedded nu code) that must survive the remote
# shell's parsing.
#
# verified against adversarial input: single quotes, semicolons, backticks,
# $(...), newlines all round-trip byte for byte; dropping this proved injection.

export def sh [s: string]: nothing -> string {
  "'" + ($s | str replace -a "'" "'\\''") + "'"
}
