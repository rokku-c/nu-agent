# edit.nu — change part of a file (local or remote)
#
#   use edit.nu
#   edit a.txt --old "let x = 1" --new "let x = 2"       # replace the first hit
#   edit a.txt --old "unwrap()" --new "expect(\"…\")" --all
#   edit a.txt --from 3 --to 5 --content "these three lines"
#   edit /etc/nginx/nginx.conf --old a --new b --host prod
#
# ── two ways to say where, one tool ──
# --old/--new replaces text, which is how an edit is usually described: the model
# has just read the file and has the exact string in front of it. --from/--to
# replaces a line range, which is what to reach for when the region is easier to
# point at than to quote.
#
# the two are deliberately not positional. `edit p a b` could be a range or a
# replacement and a wrong guess edits the wrong thing; naming the mode makes the
# call self-describing, which is what a tool schema is for.
#
# conservative in the same way write is:
#   - it errors when --old cannot be found, instead of silently doing nothing
#   - it replaces only the first hit unless --all, and reports the rest

use ../core/fileio.nu

def replace-text [
  path: path, old: string, new: string, all: bool, host: any, max_bytes: int
]: nothing -> string {
  if ($old | is-empty) {
    error make { msg: "--old must not be empty" }
  }

  let text = (fileio read-target $path $host $max_bytes)
  # split row splits literally, so the number of occurrences = segments - 1
  let found = (($text | split row $old | length) - 1)
  if $found == 0 {
    error make { msg: $"cannot find this text in (fileio where-label $path $host): ($old)" }
  }

  # if the source file is CRLF, normalize the bare newlines in the replacement
  # text too, so one file does not end up with two kinds of line ending
  let style = (fileio line-style $text)
  let new_text = (fileio to-style $new $style.sep)

  let out = (
    if $all { $text | str replace -a $old $new_text } else { $text | str replace $old $new_text }
  )
  fileio write-target $path $out $host

  let replaced = (if $all { $found } else { 1 })
  let remain = ($found - $replaced)
  let note = (if $remain > 0 { $",($remain) more occurrences are left — pass --all for those" } else { "" })
  $"replaced ($replaced) occurrence\(s\) in (fileio where-label $path $host)($note)"
}

def replace-range [
  path: path, start: int, end: int, content: string, host: any, max_bytes: int
]: nothing -> string {
  let text = (fileio read-target $path $host $max_bytes)
  let style = (fileio line-style $text)
  let cur = ($text | lines)
  let total = ($cur | length)

  if $start < 1 { error make { msg: $"--from must be >= 1, got ($start)" } }
  if $end < $start { error make { msg: $"--to ($end) cannot be less than --from ($start)" } }
  if $end > $total { error make { msg: $"line range ($start)-($end) goes past the file's ($total) lines" } }

  let new = ($content | lines)
  let merged = ($cur | first ($start - 1) | append $new | append ($cur | skip $end))

  # reassemble with the detected separator, keeping the trailing newline as it was —
  # that way an LF file and a CRLF file both come back byte-identical
  let body = ($merged | str join $style.sep)
  let out = (if $style.trailing { $body + $style.sep } else { $body })
  fileio write-target $path $out $host

  $"replaced lines ($start)-($end) of (fileio where-label $path $host): ($end - $start + 1) lines → ($new | length) lines, file is now ($merged | length) lines"
}

export def main [
  path: path                # file path
  --old (-o): string        # text to find (matched literally, not as a regex)
  --new (-n): string        # what to replace it with
  --all (-a)                # replace every occurrence; without it only the first
  --from: int               # line mode: first line to replace, 1-based
  --to: int                 # line mode: last line, this one included
  --content (-c): string    # line mode: what those lines become
  --host: string            # operate on a registered remote host
  --max-bytes: int = $fileio.DEFAULT_EDIT_MAX
]: nothing -> string {
  if $from != null or $to != null {
    if $from == null or $to == null {
      error make { msg: "line mode needs both --from and --to" }
    }
    if $content == null {
      error make { msg: "line mode needs --content: what the lines become" }
    }
    if $old != null or $new != null {
      error make { msg: "--from/--to and --old/--new are two different edits; give one or the other" }
    }
    return (replace-range $path $from $to $content $host $max_bytes)
  }

  if $old == null or $new == null {
    error make { msg: "give --old and --new to replace text, or --from/--to and --content to replace lines" }
  }
  replace-text $path $old $new ($all | default false) $host $max_bytes
}
