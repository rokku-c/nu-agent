# fileio.nu — reading and writing a file, local or remote (internal)
#
# Shared by `write` and `edit`, which are the two tools that need it. It lives
# here rather than being exported from one of them because an exported helper
# becomes a tool: the MCP allowlist is per module, so anything public in
# tools/write.nu is lent to the model. A hidden module keeps the tool surface at
# the two commands that were meant to be on it.
#
# line endings: the source file's LF vs CRLF is detected and kept as-is on write,
# trailing newline included. (nu's `lines` eats \r, so a naive join silently turns
# a CRLF file into LF.)

use ../tools/host.nu
use ./reason.nu

# per-call read/write cap. editing needs the whole file read in, so looser than
# read's.
export const DEFAULT_EDIT_MAX = 5_000_000

# detect the line ending and the trailing newline. lines eats \r, so this has to
# be probed separately.
export def line-style [text: string]: nothing -> record {
  let crlf = ($text | str contains ((char cr) + (char nl)))
  {
    sep: (if $crlf { (char cr) + (char nl) } else { char nl })
    trailing: ($text | str ends-with (char nl))
  }
}

# normalize the line endings in text to the target style (collapse to LF first,
# then expand, so nothing is replaced twice)
export def to-style [text: string, sep: string]: nothing -> string {
  if $sep == (char nl) {
    $text
  } else {
    $text | str replace -a $sep (char nl) | str replace -a (char nl) $sep
  }
}

export def read-target [path: path, host: any, max_bytes: int]: nothing -> string {
  if $host == null {
    if not ($path | path exists) {
      error make { msg: $"file not found: ($path)" }
    }
    try {
      open --raw $path | into string
    } catch {|e| error make { msg: $"cannot read ($path): (reason $e)" } }
  } else {
    if not (host exists $host $path) {
      error make { msg: $"remote file not found: ($path) @ ($host)" }
    }
    host fetch $host $path --max-bytes $max_bytes
  }
}

export def write-target [path: path, content: string, host: any]: nothing -> nothing {
  if $host == null {
    # save creates parent directories on its own
    $content | save -f $path
  } else {
    host put $host $path $content
  }
  null
}

export def target-exists [path: path, host: any]: nothing -> bool {
  if $host == null { $path | path exists } else { host exists $host $path }
}

export def where-label [path: path, host: any]: nothing -> string {
  if $host == null { $"($path)" } else { $"($host):($path)" }
}

export def line-count [text: string]: nothing -> int {
  ($text | lines | length)
}
