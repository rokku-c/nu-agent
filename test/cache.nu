#!/usr/bin/env nu
# cache.nu — the TTL store, which is also the archive of every fetch
#
# hermetic: the store is pointed at a temp directory, so nothing here touches a real one.
# the cases are order-dependent by design — the store is state, and a couple of them are
# about what happens to state over time (expiry, clearing).

use ./harness.nu *
use ./../apps/financial/cache.nu

$env.NU_AGENT_CACHE_DIR = ($nu.temp-dir | path join $"nu-agent-cache-test-(random int 100000..999999)")
mkdir $env.NU_AGENT_CACHE_DIR

let results = [
  # ── the cadence table ──
  (case "ttl: each source declares its own cadence" {
    (eq "ttl: each source declares its own cadence" [(cache ttl nyfed) (cache ttl worldbank) (cache ttl treasury)] [6hr 7day 24hr])
  })

  (case "ttl: an undeclared source gets the default, not no caching" {
    (eq "ttl: an undeclared source gets the default, not no caching" (cache ttl "who-knows") 24hr)
  })

  # ── store and retrieve ──
  (case "put/get: a payload round-trips" {
    cache put "https://example.test/a" {a: 1, b: [2 3]} --source nyfed | ignore
    (eq "put/get: a payload round-trips" (cache lookup "https://example.test/a").payload {a: 1, b: [2 3]})
  })

  (case "put/get: the payload is stored verbatim, string and all" {
    # measured: the ECB answers with a string, not a parsed record. the cache must not
    # helpfully parse it — the parse belongs to the caller, which is exactly why a parser
    # fix never costs a refetch.
    cache put "https://example.test/ecb" "{\"a\":1}" --source ecb | ignore
    (eq "put/get: the payload is stored verbatim, string and all" (cache lookup "https://example.test/ecb").payload "{\"a\":1}")
  })

  (case "get: an unknown url is null, not an error" {
    (eq "get: an unknown url is null, not an error" (cache lookup "https://example.test/never") null)
  })

  (case "the store is keyed by URL, so two requests are two entries" {
    cache put "https://example.test/one" {v: 1} | ignore
    cache put "https://example.test/two" {v: 2} | ignore
    (eq "the store is keyed by URL, so two requests are two entries" [
      (cache lookup "https://example.test/one").payload.v (cache lookup "https://example.test/two").payload.v
    ] [1 2])
  })

  # ── expiry ──
  (case "get: an expired entry is null, not the value carrying a stale flag" {
    # "the value, but stale" is the shape of bug that gets used anyway and is wrong by an
    # unknown amount. an expired entry is simply gone as far as a caller can tell.
    cache put "https://example.test/a" {a: 1} --source nyfed --ttl 0sec | ignore
    (eq "get: an expired entry is null, not the value carrying a stale flag" (cache lookup "https://example.test/a") null)
  })

  (case "put: --ttl overrides the source's declared cadence" {
    cache put "https://example.test/ttl" {a: 1} --source worldbank --ttl 1ns | ignore
    (eq "put: --ttl overrides the source's declared cadence" (cache lookup "https://example.test/ttl") null)
  })

  (case "ttl: a longer declared cadence survives a fetch that a shorter one would not" {
    cache put "https://example.test/long" {a: 1} --source worldbank | ignore
    (is-true "ttl: a longer declared cadence survives a fetch that a shorter one would not" ((cache lookup "https://example.test/long") != null))
  })

  # ── the index ──
  (case "list: shows what is stored and whether it is still fresh" {
    cache purge | ignore
    cache put "https://example.test/fresh" {v: 1} --source eurostat | ignore
    cache put "https://example.test/stale" {v: 2} --source eurostat --ttl 0sec | ignore
    let l = (cache list)
    (eq "list: shows what is stored and whether it is still fresh" [($l | length) (($l | get fresh | sort))] [2 [false true]])
  })

  (case "list: reports the source and the expiry, so the archive is navigable" {
    let row = (cache list | where url == "https://example.test/fresh" | first)
    (eq "list: reports the source and the expiry, so the archive is navigable" [$row.source ($row.expires_at | describe)] ["eurostat" "string"])
  })

  (case "info: counts entries and names the sources present" {
    let i = (cache info)
    (eq "info: counts entries and names the sources present" [$i.entries $i.sources] [2 ["eurostat"]])
  })

  # ── clearing ──
  (case "clear: removes every stored response" {
    cache purge | ignore
    (eq "clear: removes every stored response" (cache list) [])
  })

  (case "clear: says so rather than failing when there is nothing to clear" {
    (has "clear: says so rather than failing when there is nothing to clear" (cache purge) "nothing to clear")
  })

  (case "info: an empty store reports zero rather than erroring" {
    let i = (cache info)
    (eq "info: an empty store reports zero rather than erroring" [$i.entries $i.fresh $i.sources] [0 0 []])
  })
]

emit $results
