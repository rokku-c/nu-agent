# image.nu — display an image inline in a kitty-graphics terminal
#
#   use image.nu
#   image show logo.png
#   image show photo.jpg --width 40          # 40 terminal cells wide
#   image info photo.jpg
#
# ── what actually happens ──
# nushell has no image support of its own (nothing in scope commands matches
# image/kitty/sixel) and `$env.config.use_kitty_protocol` is about the keyboard
# protocol, not pictures. What makes this possible is the TERMINAL: ghostty
# implements the kitty graphics protocol (its binary carries the handlers), so
# emitting the escape sequence is enough.
#
# This will silently do nothing visible in a terminal without that support
# (Terminal.app, and anything over a plain ssh session with TERM=xterm*).
#
# ── the protocol, in short ──
#   ESC _ G <key=value,...> ; <base64 payload> ESC \
#    f=100  payload is PNG      a=T  transmit and display
#    c=/r=  size in terminal cells
#    m=1    more chunks follow, m=0 the last one
# The payload must be split into chunks of at most 4096 base64 bytes.

const CHUNK = 4096

def esc []: nothing -> string { char -i 27 }

# A path in a format the model APIs accept (png/jpeg/gif/webp). Anything else
# is converted with sips, which every macOS has; the copy lands in the temp dir.
# Converting an already-supported format would be pointless work, and turning a
# JPEG into PNG would inflate it — a lossless re-encode of a lossy original.
export def as-supported [path: path]: nothing -> path {
  let p = ($path | path expand)
  if not ($p | path exists) {
    error make { msg: $"no such file: ($p)" }
  }
  let ext = ($p | path parse | get extension | str lowercase)
  if $ext in ["png" "jpg" "jpeg" "gif" "webp"] {
    return $p
  }
  let out = ($nu.temp-dir | path join $"image-($p | path parse | get stem).png")
  let r = (^sips -s format png $p --out $out | complete)
  if $r.exit_code != 0 {
    error make { msg: $"could not convert to PNG: ($r.stderr | str trim)" }
  }
  $out
}

# Show an image inline.
export def show [
  path: path          # image file (PNG directly; anything else via sips)
  --width (-w): int   # width in terminal cells
  --height (-r): int  # height in terminal cells
  --id: int           # image id, if you want to place/delete it later
]: nothing -> nothing {
  let png = (as-supported $path)
  let b64 = (open --raw $png | encode base64)
  let e = (esc)

  let params = (
    ["f=100" "a=T"]
    | append (if $width == null { [] } else { [$"c=($width)"] })
    | append (if $height == null { [] } else { [$"r=($height)"] })
    | append (if $id == null { [] } else { [$"i=($id)"] })
    | str join ","
  )

  let n = (($b64 | str length) / $CHUNK | math ceil | into int)
  # Chunked because the protocol caps a single payload at 4096 base64 bytes.
  # print -n so nothing is inserted between the escape and its payload.
  for i in 0..<$n {
    let part = ($b64 | str substring ($i * $CHUNK)..((($i + 1) * $CHUNK) - 1))
    let more = (if $i < ($n - 1) { 1 } else { 0 })
    let head = (if $i == 0 { $"($e)_G($params),m=($more);" } else { $"($e)_Gm=($more);" })
    print -n $"($head)($part)($e)\\"
  }
}

# Basic facts about an image, straight from sips.
export def info [path: path]: nothing -> record {
  let p = ($path | path expand)
  if not ($p | path exists) { error make { msg: $"no such file: ($p)" } }
  let r = (^sips -g pixelWidth -g pixelHeight -g format $p | complete)
  if $r.exit_code != 0 {
    error make { msg: $"sips could not read it: ($r.stderr | str trim)" }
  }
  let get = {|k| $r.stdout | lines | where {|l| $l | str contains $k } | first | split row ":" | last | str trim }
  {
    path: ($p | into string)
    width: ((do $get "pixelWidth") | into int)
    height: ((do $get "pixelHeight") | into int)
    format: (do $get "format")
    bytes: ((ls $p).0.size | into int)
  }
}
