# calc.nu — a safe arithmetic calculator
#
#   use calc.nu
#   calc "2+2"              # 4
#   calc "(1+2)*3"          # 9
#   calc "100 / 7"          # 14.285714285714286
#   calc "2^10"             # 1024
#   calc "10 % 3"           # 1
#
# why normalise: nu requires whitespace on both sides of a binary operator, so `2+3`
# is taken as an external command and errors with `Command '2+3' not found`. Models (and
# people) write `2+3` naturally, so first rewrite the expression into a form nu can parse.
#
# safety boundary: only digits, scientific notation, + - * / % ^ ( ) and whitespace
# are accepted, everything else is rejected. So `2; rm -rf /` and `sqrt(16)` can't get
# in — this is a calculator, not an eval.

# rewrite common spellings into a form nu can parse
def normalize [expr: string]: nothing -> string {
  # unify the modulo spelling first, so the whitelist below needn't allow letters
  let e = ($expr | str replace -r -a '(?i)\bmod\b' '%' | str trim)

  # whitelist check is "delete and see what's left", since 0.116's str contains has no --regex
  let leftover = ($e | str replace -r -a '[0-9eE.+*/%^() \t-]' '')
  if ($leftover | is-not-empty) {
    error make { msg: $"expression contains disallowed characters: ($leftover). only digits and + - * / % ^ \( \) are supported" }
  }

  $e
  # sentinels hide exponentiation first, else the * spacing below splits ** into * *
  | str replace -a '**' ' POWTOK '
  | str replace -a '^' ' POWTOK '
  | str replace -a '%' ' MODTOK '
  | str replace -r -a '([+*/(])' ' $1 '
  | str replace -r -a '(\))' ' $1 '
  # a minus is a binary operator only after a digit or a closing paren.
  # otherwise -5 becomes - 5 and nu throws parse_mismatch; this also preserves 1e-3
  | str replace -r -a '([0-9)])-' '$1 - '
  | str replace -a 'POWTOK' '**'
  | str replace -a 'MODTOK' 'mod'
  | str replace -r -a ' +' ' '
  | str trim
}

# evaluate an arithmetic expression and return a numeric result.
# use this for maths rather than working it out in your head — mental maths goes wrong.
export def main [
  expr: string   # arithmetic expression, e.g. "(1+2)*3", "100/7", "2^10", "10%3"
]: nothing -> any {
  let norm = (normalize $expr)

  # nu has no in-process eval, so into a subprocess it goes. no --config here:
  # pure arithmetic needs no modules, which skips the cost of loading config
  let r = (^nu -c $norm | complete)
  if $r.exit_code != 0 {
    error make { msg: $"evaluation failed: ($r.stderr | str trim)" }
  }

  let out = ($r.stdout | str trim)
  if ($out | is-empty) {
    error make { msg: $"expression produced no result: ($expr)" }
  }

  # can't blindly into int — it silently truncates "3.5" to 3 instead of erroring.
  # so go by looks: a decimal point or exponent means float, otherwise int.
  if (($out | str contains '.') or ($out | str contains 'e') or ($out | str contains 'E')) {
    try { $out | into float } catch { $out }
  } else {
    try { $out | into int } catch { $out }
  }
}
