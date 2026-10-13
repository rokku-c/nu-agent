# cache.nu — a TTL'd store for source responses, which doubles as the archive of every fetch
#
# two jobs, one file, because they want the same thing stored:
#
#   · a CACHE, so a daily workflow does not refetch an annual indicator every morning.
#     each source declares its own cadence — not a guess about the API, but the rate the
#     data itself changes at. refetching World Bank annual GDP six times before lunch is
#     six identical requests.
#
#   · an ARCHIVE, because "what did the source say, and when did it say it" is a question
#     that comes up later and cannot be answered after the fact. and because re-parsing a
#     stored payload is how a parser fix gets applied without going back to the network.
#
# what is stored is the RAW payload, keyed by the request URL — never the parsed result.
# a parsed-object cache would have to be thrown away every time a parser changed, which is
# exactly when you least want to spend a network round trip.
#
# this is the first piece of §I's "vintage snapshots": the store that makes point-in-time
# questions answerable later. it does not make a source serve history it does not have —
# it records what was seen, from the day this starts running.
#
# ── two names are not the obvious ones ──
# `get` and `clear` are nushell builtins, and a subcommand of the same name shadows them
# *inside this module*. `get` shadowed nu's own get and broke `$TTL | get --optional …` on
# the first run — measured, not anticipated. hence `lookup` and `purge`. (write.nu carries
# the same note about append / lines / insert / save.)

const DIR_NAME = "nu-agent-cache"

# how long a response stays usable, by source. the values are the data's own update cadence.
const TTL = {
  nyfed: 6hr       # a daily rate, published once each business day
  ecb: 6hr         # daily series; the monthly ones are overwritten in place
  fred: 6hr
  treasury: 24hr   # monthly records
  eurostat: 24hr   # monthly and quarterly releases
  worldbank: 7day  # annual indicators, and slow to revise
  transcribed: 7day # a document read by a model does not change under you
  # market sources. these are the ones where a stale value is actively misleading, so the
  # cadence is short for anything that moves during a session and long only for daily fixes.
  sina-quote: 5min      # a live snapshot: it is wrong the moment the market moves
  sina-kline: 6hr       # daily bars, settled after the close
  treasury-curve: 24hr  # published once each business day
  frankfurter: 24hr     # one ECB fixing per business day
  default: 24hr    # an undeclared source is cached for a day rather than not at all
}

def now-epoch []: nothing -> int {
  (date now | format date "%s") | into int
}

def store-dir []: nothing -> path {
  # NU_AGENT_CACHE_DIR overrides the location — for test isolation, or a store per project
  let override = ($env.NU_AGENT_CACHE_DIR? | default "")
  if ($override | is-empty) {
    $nu.data-dir | path join $DIR_NAME
  } else {
    $override | path expand
  }
}

# the URL is the identity of a request, so it is the key. hashed, because a URL is not a
# filename; the readable form is kept inside the entry so the index stays legible.
def entry-path [url: string]: nothing -> path {
  store-dir | path join $"($url | hash md5).json"
}

# the declared cadence for a source, or the default when it declares none
export def ttl [source: string]: nothing -> duration {
  $TTL | get --optional $source | default $TTL.default
}

# where the store lives, and a one-line summary of it
export def info []: nothing -> record {
  let dir = (store-dir)
  let entries = (
    if ($dir | path exists) {
      glob ($dir | path join "*.json") | each {|f| try { open $f } catch { null } } | compact
    } else { [] }
  )
  {
    dir: ($dir | into string)
    entries: ($entries | length)
    fresh: ($entries | where {|e| $e.expires_epoch > (now-epoch)} | length)
    sources: ($entries | get source | uniq | sort)
  }
}

# the index: what is stored, from where, and until when
export def list []: nothing -> any {
  let dir = (store-dir)
  if not ($dir | path exists) { return [] }
  glob ($dir | path join "*.json")
  | each {|f| try { open $f } catch { null } }
  | compact
  | each {|e|
      {
        source: $e.source
        url: $e.url
        fetched_at: $e.fetched_at
        expires_at: ($e.expires_epoch | into datetime | format date "%Y-%m-%d %H:%M")
        fresh: ($e.expires_epoch > (now-epoch))
      }
    }
  | sort-by source url
}

# the stored entry for a request, when it is still fresh.
#
# an expired entry is not returned at all rather than returned with a flag: "the value, but
# stale" is the shape of bug that gets used anyway and is wrong by an unknown amount.
export def lookup [url: string]: nothing -> any {
  let p = (entry-path $url)
  if not ($p | path exists) { return null }
  let e = (try { open $p } catch { null })
  if $e == null { return null }
  if ($e.expires_epoch > (now-epoch)) { $e } else { null }
}

# store a response — whether it came from the network or from a transcription
export def put [
  url: string
  payload: any
  --source: string = "unknown"
  --ttl: duration
]: nothing -> record {
  mkdir (store-dir)
  let d = ($ttl | default (ttl $source))
  let now = (now-epoch)
  let e = {
    url: $url
    source: $source
    fetched_at: (date now | format date "%Y-%m-%dT%H:%M:%S")
    fetched_epoch: $now
    expires_epoch: ($now + (($d / 1sec) | into int))
    ttl_secs: (($d / 1sec) | into int)
    payload: $payload
  }
  $e | save -f (entry-path $url)
  $e
}

# get-or-fetch. the call every source goes through.
#
# note the payload is returned exactly as it arrived: for most sources that is a parsed
# record, for the ECB it is a string, because that endpoint's content type is not one nu
# treats as JSON. parsing is the caller's step, and deliberately so — a stored payload must
# be re-readable by a parser that has since changed.
export def fetch [
  url: string
  --source: string = "unknown"
  --ttl: duration
  --refresh            # fetch even when a fresh entry exists
  --header: record     # request headers — some sources require a User-Agent or a Referer
  --decode: string     # decode the body with this encoding before storing it. load-bearing
                       # for the Chinese sources, which answer in GBK: a binary body cannot
                       # be stored as JSON, and decoding here keeps the store text-only.
]: nothing -> record {
  if not $refresh {
    let hit = (lookup $url)
    if $hit != null {
      return ($hit | insert cached true)
    }
  }
  let raw = (if $header == null { http get $url } else { http get -H $header $url })
  let payload = (if $decode == null { $raw } else { $raw | decode $decode })
  let e = (put $url $payload --source $source --ttl ($ttl | default (ttl $source)))
  $e | insert cached false
}

# drop every stored response. the archive is the point, so this is the one destructive call
# here — it exists for test isolation and for a store that has been corrupted, not for
# routine use.
export def purge []: nothing -> string {
  let dir = (store-dir)
  if not ($dir | path exists) { return "nothing to clear" }
  let paths = (glob ($dir | path join "*.json"))
  if ($paths | is-empty) { return "nothing to clear" }
  rm -f ...$paths
  $"removed ($paths | length) stored responses from ($dir)"
}
