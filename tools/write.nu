# write.nu — write files (local or remote)
#
#   use write.nu
#   write file  a.txt "new content"       # overwrite the whole file
#   write file  a.txt "content" --create  # create a new file (not allowed by default)
#   write range a.txt 3 5 "these three lines"  # replace lines 3-5
#   write replace a.txt "old" "new"       # find and replace (first hit only by default)
#   write replace a.txt "old" "new" --all # replace every hit
#
#   # remote (register the host with host first)
#   write replace /etc/nginx/nginx.conf "old" "new" --host prod
#
# a few deliberately conservative choices:
#   - `file` does not create new files by default, so a mistyped path cannot silently produce an empty file
#   - `replace` errors when it cannot find the target, instead of silently doing nothing
#   - `replace` replaces only the first hit by default and reports the rest — better to under-edit than silently over-edit
#
# subcommands deliberately avoid the builtin names append / lines / insert / save —
# a same-named definition in a module shadows the builtin, and this file needs them.
#
# line endings: the source file's LF vs CRLF is detected and kept as-is on write, trailing
# newline included. (nu's `lines` eats \r, so a naive join silently turns a CRLF file into LF.)

use ./host.nu

# remote per-call read/write cap. editing needs the whole file read in, so looser than read's
const DEFAULT_EDIT_MAX = 5_000_000

# detect the line ending and the trailing newline. lines eats \r, so this has to be probed separately
def line-style [text: string]: nothing -> record {
  let crlf = ($text | str contains ((char cr) + (char nl)))
  {
    sep: (if $crlf { (char cr) + (char nl) } else { char nl })
    trailing: ($text | str ends-with (char nl))
  }
}

# normalize the line endings in text to the target style (collapse to LF first, then expand, so nothing is replaced twice)
def to-style [text: string, sep: string]: nothing -> string {
  if $sep == (char nl) {
    $text
  } else {
    $text | str replace -a $sep (char nl) | str replace -a (char nl) $sep
  }
}

# ── unified local/remote read and write ──

def read-target [path: path, host: any, max_bytes: int]: nothing -> string {
  if $host == null {
    if not ($path | path exists) {
      error make { msg: $"file not found: ($path)" }
    }
    try {
      open --raw $path | into string
    } catch {|e|
      error make { msg: $"cannot read ($path): ($e.msg)" }
    }
  } else {
    if not (host exists $host $path) {
      error make { msg: $"remote file not found: ($path) @ ($host)" }
    }
    host fetch $host $path --max-bytes $max_bytes
  }
}

def write-target [path: path, content: string, host: any]: nothing -> nothing {
  if $host == null {
    # save creates parent directories on its own
    $content | save -f $path
  } else {
    host put $host $path $content
  }
  null
}

def target-exists [path: path, host: any]: nothing -> bool {
  if $host == null { $path | path exists } else { host exists $host $path }
}

def where-label [path: path, host: any]: nothing -> string {
  if $host == null { $"($path)" } else { $"($host):($path)" }
}

def line-count [text: string]: nothing -> int {
  ($text | lines | length)
}

# ── subcommands ──

# overwrite the whole file
export def file [
  path: path        # file path
  content: string   # full content
  --create          # allow creating a new file; without it only existing files can be overwritten
  --host: string    # operate on a registered remote host
]: nothing -> string {
  let exists = (target-exists $path $host)
  if (not $exists) and (not $create) {
    error make { msg: $"file not found: (where-label $path $host). pass --create to make a new one" }
  }
  write-target $path $content $host
  let verb = (if $exists { "overwrote" } else { "created" })
  $"($verb) (where-label $path $host), (line-count $content) lines, ($content | str length) bytes"
}

# replace a line range (start and end are 1-based, both ends included)
export def range [
  path: path        # file path
  start: int        # first line, 1-based
  end: int          # last line, this one included
  content: string   # what to replace them with
  --host: string    # operate on a registered remote host
  --max-bytes: int = $DEFAULT_EDIT_MAX
]: nothing -> string {
  let text = (read-target $path $host $max_bytes)
  let style = (line-style $text)
  let cur = ($text | lines)
  let total = ($cur | length)

  if $start < 1 {
    error make { msg: $"start must be >= 1, got ($start)" }
  }
  if $end < $start {
    error make { msg: $"end ($end) cannot be less than start ($start)" }
  }
  if $end > $total {
    error make { msg: $"line range ($start)-($end) goes past the file's ($total) lines" }
  }

  let new = ($content | lines)
  let merged = (
    ($cur | first ($start - 1))
    | append $new
    | append ($cur | skip $end)
  )

  # reassemble with the detected separator, keeping the trailing newline as it was —
  # that way an LF file and a CRLF file both come back byte-identical
  let body = ($merged | str join $style.sep)
  let out = (if $style.trailing { $body + $style.sep } else { $body })
  write-target $path $out $host

  $"replaced lines ($start)-($end) of (where-label $path $host): ($end - $start + 1) lines → ($new | length) lines, file is now ($merged | length) lines"
}

# find and replace. only the first hit by default; --all replaces every one
export def replace [
  path: path        # file path
  old: string       # text to find (matched literally, not as a regex)
  new: string       # what to replace it with
  --all             # replace every occurrence; without it only the first
  --host: string
  --max-bytes: int = $DEFAULT_EDIT_MAX
]: nothing -> string {
  if ($old | is-empty) {
    error make { msg: "old must not be empty" }
  }

  let text = (read-target $path $host $max_bytes)
  # split row splits literally, so the number of occurrences = segments - 1
  let found = (($text | split row $old | length) - 1)
  if $found == 0 {
    error make { msg: $"cannot find this text in (where-label $path $host): ($old)" }
  }

  # if the source file is CRLF, normalize the bare newlines in the replacement text
  # too, so one file does not end up with two kinds of line ending
  let style = (line-style $text)
  let new_text = (to-style $new $style.sep)

  let out = (
    if $all {
      $text | str replace -a $old $new_text
    } else {
      $text | str replace $old $new_text
    }
  )
  write-target $path $out $host

  let replaced = (if $all { $found } else { 1 })
  let remain = ($found - $replaced)
  let note = (if $remain > 0 { $",($remain) more occurrences are left unreplaced — pass --all to replace them all" } else { "" })
  $"replaced ($replaced) occurrences($note)"
}
