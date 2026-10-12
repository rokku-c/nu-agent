# transport.nu — the one place a request is actually executed (internal)
#
# every provider goes through here, so the two awkward facts about doing HTTP
# from nushell live in exactly one file.
#
# ── why two different mechanisms ──
# non-streaming goes through nu's `http post`: it is in-process, has a timeout,
# and `--allow-errors --full` hands back the status instead of throwing, which
# is what lets an error body be read as data.
#
# streaming cannot. nu's `http post` has no streaming callback — it returns only
# after the whole body is read, which defeats the point. measured: nu reads
# **external processes** streaming (line by line, not buffered), so the stream
# path shells out to curl -N and reduces over its lines.

# one non-streaming POST. returns nu's {status, body, headers}; a non-200 status
# is NOT an error here, because the provider decides what an error body means.
export def post [
  url: string
  headers: record
  body: record
  timeout: duration
]: nothing -> record {
  (
    http post --allow-errors --full --max-time $timeout
      --content-type "application/json"
      --headers $headers
      $url
      $body
  )
}

# one streaming POST. `step` is called per line as (line, acc) -> acc, and the
# final accumulator is returned.
#
# the body goes out as a single -d argument and every header as its own -H, with
# no shell anywhere in the chain, so nothing is re-split or escaped.
export def stream [
  url: string
  headers: record
  body: record
  timeout: duration
  seed: record
  step: closure
]: nothing -> record {
  let secs = ((($timeout | into int) / 1000000000) | math floor | into string)

  let argv = (
    ["curl" "-sS" "-N" "--max-time" $secs "-X" "POST" $url]
    | append (
        $headers
        | transpose k v
        | each {|h| ["-H" $"($h.k): ($h.v)"] }
        | flatten
      )
    | append ["-d" ($body | to json -r)]
  )

  # reduce, not each: each's closure cannot capture a mutable variable, so it
  # cannot accumulate state. same reason apply-event is a pure function.
  run-external ($argv | first) ...($argv | skip 1)
  | lines
  | reduce --fold $seed {|l, acc| do $step $l $acc }
}
