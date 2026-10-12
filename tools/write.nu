# write.nu — write a whole file (local or remote)
#
#   use write.nu
#   write a.txt "new content"          # overwrite the whole file
#   write a.txt "content" --create     # create a new file (not allowed by default)
#   write /etc/nginx/nginx.conf "…" --host prod
#
# ── why this is one command and not three ──
# it used to carry `file`, `range` and `replace`, which the tool generator turned
# into `write_file`, `write_range` and `write_replace` — three tools for what a
# model thinks of as two actions, write and edit. `edit` now has the modifying
# pair; this is the whole-file write, and its tool name is just `write`.
#
# deliberately conservative: it does not create a new file unless --create is
# passed, so a mistyped path cannot silently produce an empty file.

use ../core/fileio.nu

# overwrite the whole file
export def main [
  path: path        # file path
  content: string   # full content
  --create          # allow creating a new file; without it only existing files can be overwritten
  --host: string    # operate on a registered remote host
]: nothing -> string {
  let exists = (fileio target-exists $path $host)
  if (not $exists) and (not $create) {
    error make { msg: $"file not found: (fileio where-label $path $host). pass --create to make a new one" }
  }
  fileio write-target $path $content $host
  let verb = (if $exists { "overwrote" } else { "created" })
  $"($verb) (fileio where-label $path $host), (fileio line-count $content) lines, ($content | str length) bytes"
}
