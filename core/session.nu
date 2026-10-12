# session.nu — persist a run and resume it later
#
#   use session.nu
#
#   session list                        # what is stored
#   session show ses-…                  # counters and provenance
#   session show ses-… --index 7        # one raw message
#   session last                        # the most recently updated
#   session prune --keep 20             # delete old / orphaned entries
#
#   agent "…" --session ses-…           # continue an existing session
#   agent "…" --resume                  # continue the newest one
#   agent "…" --session new-thing       # start one with this id
#
# ── the invariant everything else follows from ──
#
#   A session stores the CANONICAL, UNFOLDED message list. Folding is a derived
#   view of a run and is never persisted.
#
# this is not a stylistic preference, it is the difference between resuming and
# corrupting. the loop reassigns its working `$messages` to the folded copy
# whenever the context is trimmed, so the message list a run finishes with is
# full of `[folded] item 7 …` placeholders. persisting that is the double-fold
# trap: resuming hands the model placeholders instead of its own history, and
# folding again folds the placeholders.
#
# so the loop carries a second, append-only variable that folding never touches
# (see `canonical` in agent.nu), and that is what gets written here.
#
# ── what is stored as provenance rather than as a value ──
# `tools` and `skill` are stored as *where to get them* (module names, file
# paths), never as resolved content. MCP tool definitions are not stable across
# runs — a server can be down, a module can be renamed — and freezing
# yesterday's input_schema list would replay a stale tool set. a skill's path
# re-reads an edited file; its body would freeze it.
#
# images likewise store paths, not base64: a 10 MB screenshot would otherwise
# make every session file 10 MB, and `session list` reads every file.

const DIR_NAME = "agent-sessions"

# store location. NU_SESSION_DIR overrides it — for test isolation, or a store
# per project. same convention as the context store.
export def store-dir []: nothing -> path {
  let override = ($env.NU_SESSION_DIR? | default "")
  if ($override | is-empty) {
    $nu.data-dir | path join $DIR_NAME
  } else {
    $override | path expand
  }
}

def entry-path [id: string]: nothing -> path {
  store-dir | path join $"($id).json"
}

export def new-id []: nothing -> string {
  $"ses-((date now | format date '%Y%m%d-%H%M%S'))-((random int 1000..9999))"
}

export def exists [id: string]: nothing -> bool {
  (entry-path $id) | path exists
}

# ── reading ──

export def load [id: string]: nothing -> record {
  let p = (entry-path $id)
  if not ($p | path exists) {
    error make { msg: $"session not found: ($id). run `session list` to see what exists" }
  }
  open $p
}

# the most recently updated session.
#
# note `reverse | first`, not `last`: this module exports a command named `last`,
# and a same-named export shadows the builtin **inside the module too** — so
# `… | last` here would call this very function. the same trap is recorded for
# `save` in trace.nu.
export def last []: nothing -> any {
  let all = (list)
  if ($all | is-empty) { return null }
  load ($all | sort-by updated | reverse | first | get id)
}

# an empty table. `[[a b c]]` looks like the obvious literal and is not one: it
# parses as a single row of empty strings, typed list<list<string>>, which fails
# the declared table return. `[] | select <cols>` is an empty list carrying the
# right columns.
def empty-table []: nothing -> table {
  [] | select id updated status provider model title rounds messages
}

export def list []: nothing -> table {
  let dir = (store-dir)
  if not ($dir | path exists) { return (empty-table) }
  let files = (glob ($dir | path join "*.json"))
  if ($files | is-empty) { return (empty-table) }
  $files
  | each {|f|
      # a session that cannot be parsed must not take the listing down with it
      let e = (try { open $f } catch { return null })
      {
        id: ($e | get --optional id | default ($f | path parse | get stem))
        updated: ($e | get --optional updated | default "")
        status: ($e | get --optional status | default "?")
        provider: ($e | get --optional provider | default "")
        model: ($e | get --optional model | default "")
        title: ($e | get --optional title | default "" | str substring 0..50)
        rounds: ($e | get --optional counters.rounds | default 0)
        messages: (($e | get --optional messages | default []) | length)
      }
    }
  | compact
  | sort-by updated --reverse
}

# view one session: the counters by default, one raw message with --index
export def show [
  id: string
  --index (-i): int      # show one message in full
  --full                 # dump everything, including the message list
  --limit (-l): int = 40 # how many messages the overview previews
]: nothing -> any {
  let e = (load $id)
  if $full { return $e }

  let msgs = ($e | get --optional messages | default [])

  if $index != null {
    if $index < 0 or $index >= ($msgs | length) {
      error make { msg: $"index out of range: ($index), valid range 0..(($msgs | length) - 1)" }
    }
    return ($msgs | get $index)
  }

  let head = {
    id: $e.id
    status: ($e | get --optional status | default "?")
    title: ($e | get --optional title | default "")
    created: ($e | get --optional created | default "")
    updated: ($e | get --optional updated | default "")
    provider: ($e | get --optional provider | default "")
    model: ($e | get --optional model | default "")
    cwd: ($e | get --optional cwd | default "")
    tools: ($e | get --optional tools | default {})
    skill: ($e | get --optional skill | default [])
    counters: ($e | get --optional counters | default {})
    messages: ($msgs | length)
    folds: (($e | get --optional folds | default []) | length)
    parent: ($e | get --optional parent | default null)
    depth: ($e | get --optional depth | default 0)
  }
  # the overview goes to stderr, so `session show $id | to json` stays clean
  $head | print -e

  $msgs
  | enumerate
  | first $limit
  | each {|r|
      let m = $r.item
      let c = ($m | get --optional content)
      let kind = (
        if (($c | describe) | str starts-with "list") or (($c | describe) | str starts-with "table") { "blocks" } else { "text" }
      )
      {
        i: $r.index
        role: ($m | get --optional role | default "?")
        kind: $kind
        preview: (
          if $kind == "blocks" { $"($c | length) blocks" }
          else { ($c | into string | str substring 0..( [ 70 ($c | into string | str length) ] | math min )) }
        )
      }
    }
}

# ── writing ──

# write a session. the caller builds the record; this only decides the id when
# one was not given and stamps `updated`.
#
# named `store`, not `save`: a same-named export shadows the builtin inside the
# module as well, so a command called `save` could not call `save -f` to write
# the file at all. (trace.nu records the same trap for its own `write`.)
export def store []: record -> string {
  let rec = $in
  let id = ($rec | get --optional id | default null | default (new-id))
  let p = (entry-path $id)
  mkdir (store-dir)
  $rec
  | upsert id $id
  # milliseconds, not seconds: two runs finishing inside the same second made
  # `session last` pick the wrong one, and the ordering is what it is for
  | upsert updated ((date now) | format date '%Y-%m-%d %H:%M:%S%.3f')
  | save -f $p
  $id
}

# build a session record from a finished run. kept here rather than in the loop
# so the shape lives next to the reader.
export def record-of [
  id: any
  status: string
  prompt: string
  messages: list
  provider: string
  model: string
  system: any
  skill: any
  tools_from: any
  mcp: any
  images: any
  budget: record
  counters: record
  folds: list
  context_entries: list
  parent: any
  depth: int
]: nothing -> record {
  let created = (
    if $id != null and (exists $id) { (load $id | get --optional created | default "") } else { "" }
  )
  {
    id: $id
    created: (if ($created | is-empty) { ((date now) | format date '%Y-%m-%d %H:%M:%S') } else { $created })
    status: $status
    title: ($prompt | str replace -r -a '\s+' ' ' | str substring 0..([ 80 ($prompt | str length) ] | math min))
    provider: $provider
    model: $model
    system: $system
    skill: ($skill | default [])
    tools: {modules: ($tools_from | default []), mcp: ($mcp | default [])}
    cwd: ($env.PWD | into string)
    budget: $budget
    messages: $messages
    images: ($images | default [])
    counters: $counters
    folds: ($folds | default [])
    context_entries: ($context_entries | default [])
    parent: $parent
    depth: $depth
  }
}

# ── maintenance ──

# delete sessions, by age or by keeping the newest N. --dry-run reports first.
#
# the fold entries a session produced are not deleted with it: they may be
# referenced by several sessions, and an unreferenced entry costs a few KB.
export def prune [
  --keep: int = 20        # always keep the newest this many
  --older-than: duration  # also delete anything untouched for longer than this
  --dry-run
]: nothing -> table {
  let all = (list)
  let keep = ($all | sort-by updated --reverse | first $keep | get id)
  let doomed = (
    $all
    | where {|s| not ($s.id in $keep) }
    | if $older_than == null { $in } else {
        let cutoff = ((date now) - $older_than)
        $in | where {|s| (($s.updated | into datetime) < $cutoff) }
      }
  )
  if not $dry_run {
    for s in $doomed { rm -f (entry-path $s.id) }
  }
  $doomed
}

# every fold entry a session has produced, so a caller can show them or clean up
export def entries [id: string]: nothing -> list {
  (load $id) | get --optional context_entries | default []
}
