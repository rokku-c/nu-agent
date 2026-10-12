# read.nu — read files (local or remote)
#
#   use read.nu
#   read /etc/hosts
#   read src/main.rs --offset 100 --limit 50 --numbers
#   read /var/log/app.log --host prod --limit 50
#
# text files only. binaries are kept out, so gibberish doesn't flood the context.
# locally that is decided by `into string` erroring with Non-UTF8 on invalid UTF-8;
# remote has no equivalent check, see the note on read-remote.

use ./host.nu

# per-read cap, so one huge file doesn't blow up the context
const DEFAULT_MAX_BYTES = 200_000

def read-local [path: path, max_bytes: int]: nothing -> string {
  if not ($path | path exists) {
    error make { msg: $"file not found: ($path)" }
  }
  if ($path | path type) == "dir" {
    error make { msg: $"this is a directory, not a file: ($path)" }
  }

  # gate on size first. when size is unavailable (a symlink, say) take 0 and let the rest catch it
  let size = (try { (ls $path).0.size | into int } catch { 0 })
  if $size > $max_bytes {
    error make { msg: $"file is ($size) bytes, over the ($max_bytes) limit. raise it with --max-bytes" }
  }

  # a binary through into string errors with Non-UTF8 — that's the decision point here
  try {
    open --raw $path | into string
  } catch {|e|
    error make { msg: $"can't read it, probably not a text file: ($e.msg)" }
  }
}

def read-remote [host: string, path: path, max_bytes: int]: nothing -> string {
  # host fetch caps the transfer with head -c (max+1) internally and errors itself when over.
  # note: this remote path has no UTF-8 check like the local one — a binary comes back
  # lossily decoded. to pin it down, first run `shell "file <path>" --host <host>`.
  try {
    host fetch $host $path --max-bytes $max_bytes
  } catch {|e|
    error make { msg: $e.msg }
  }
}

# read a file's contents and return text.
export def main [
  path: path                              # file path
  --offset (-o): int = 1                  # line to start from, 1-based
  --limit (-l): int                       # max lines to read, reads to the end when omitted
  --numbers (-n)                          # prefix each line with a line number (tab separated)
  --max-bytes: int = $DEFAULT_MAX_BYTES   # reject outright above this size
  --host: string                          # read on a registered remote host
]: nothing -> string {
  let content = (
    if $host == null { read-local $path $max_bytes } else { read-remote $host $path $max_bytes }
  )

  let all = ($content | lines)
  let total = ($all | length)
  if $total == 0 { return "(empty file)" }

  let start = $offset
  if $start < 1 {
    error make { msg: $"offset must be >= 1, got ($start)" }
  }
  if $start > $total {
    error make { msg: $"offset ($start) is past the file's ($total) lines" }
  }

  let picked = (
    $all | skip ($start - 1)
    | if $limit == null { $in } else { first $limit }
  )
  let shown = ($picked | length)
  let last = ($start + $shown - 1)

  let body = (
    if $numbers {
      $picked | enumerate | each {|r| $"($r.index + $start)\t($r.item)" } | str join (char nl)
    } else {
      $picked | str join (char nl)
    }
  )

  # say so when truncated, else the model doesn't know it saw only part of it.
  # literal parens must be written \( \) — a bare ( is taken as an interpolation that runs a command
  if $last < $total {
    let where = (if $host == null { $path } else { $"($host):($path)" })
    $"($body)\n\n...\(($where) has ($total) lines, showing ($start)-($last), ($total - $last) left\)"
  } else {
    $body
  }
}
