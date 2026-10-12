# style.nu — unified colour helper
#
#   use style.nu
#   style ok "written successfully"
#   style warn "3 spots left unreplaced"
#   $"file (style path $p) written, (style num $n) lines"
#
# ── why this layer exists instead of writing ansi directly ──
#
# nu's own colouring (for int / string / header etc.) is applied by type
# **at render time**, and is switched off automatically when not a TTY — so
# `nu -c '[[a b];[1 2]]' | cat` carries no colour codes. That is safe.
#
# But **an explicit ansi call doesn't care**: $"(ansi green)x(ansi reset)" carries
# \x1b[…m whether or not it's piped. Return a string like that as "data" and the
# colour codes ride along into pipes, files, and the LLM's context. Verified by test.
#
# So the rule for this layer is: **use is-terminal --stdout to decide on colour**.
#   - output to a terminal  → coloured
#   - piped/captured        → falls back to plain text automatically
# That guarantees agent tool results, read content, and anything written to a
# file carry no colour codes.
#
# Why not is-redirected: it asks whether the *current custom command's return value*
# is redirected — from inside a helper that always reads as "redirected" (the value goes
# back to the caller), so it can't be used here. is-terminal is an OS-level check, stable anywhere.

# whether to colour right now. NU_STYLE=never/always forces an override
export def enabled []: nothing -> bool {
  let mode = ($env.NU_STYLE? | default "auto" | str lowercase)
  if $mode == "never" { return false }
  if $mode == "always" { return true }
  is-terminal --stdout
}

# wrap in ANSI. returned untouched when colouring is off
def paint [text: string, code: string]: nothing -> string {
  if (enabled) {
    $"(ansi $code)($text)(ansi reset)"
  } else {
    $text
  }
}

# ── semantic helpers ──

export def ok [text: string]: nothing -> string { paint $text "green" }
export def warn [text: string]: nothing -> string { paint $text "yellow" }
export def err [text: string]: nothing -> string { paint $text "red" }
export def info [text: string]: nothing -> string { paint $text "cyan" }
export def dim [text: string]: nothing -> string { paint $text "dark_gray" }
export def bold [text: string]: nothing -> string { paint $text "white_bold" }
export def path [text: string]: nothing -> string { paint $text "cyan" }
export def num [text: string]: nothing -> string { paint $text "magenta" }
export def key [text: string]: nothing -> string { paint $text "blue" }
export def code [text: string]: nothing -> string { paint $text "green" }
export def heading [text: string]: nothing -> string { paint $text "green_bold" }

# prefix a line of text with a status marker, colouring the whole line
export def mark [kind: string, text: string]: nothing -> string {
  let tag = (
    match $kind {
      "ok" => "✓"
      "warn" => "!"
      "err" => "✗"
      "info" => "·"
      _ => "·"
    }
  )
  let body = $"($tag) ($text)"
  match $kind {
    "ok" => (ok $body)
    "warn" => (warn $body)
    "err" => (err $body)
    _ => (info $body)
  }
}

# warnings always go to stderr, and only colour when stderr is a real terminal.
# a separate command because stderr and stdout can differ in TTY status.
export def warn-e [text: string]: nothing -> nothing {
  let on = (
    if ($env.NU_STYLE? | default "auto" | str lowercase) == "never" {
      false
    } else if ($env.NU_STYLE? | default "auto" | str lowercase) == "always" {
      true
    } else {
      is-terminal --stderr
    }
  )
  if $on {
    print -e $"(ansi yellow)⚠ ($text)(ansi reset)"
  } else {
    print -e $"⚠ ($text)"
  }
}
