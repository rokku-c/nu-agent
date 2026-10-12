# context.nu — context capture and folding
#
#   use context.nu
#
#   # capture a whole context, get back an entry
#   $messages | context capture --note "turn 12"
#
#   # list entries / inspect one entry's shape / read one raw message
#   context list
#   context show ctx-20260929-131500-1234
#   context show ctx-20260929-131500-1234 --index 7
#
#   # policy: what to fold, what to keep
#   context fold ctx-... 2 3 4
#   context keep ctx-... 0
#
#   # one shot: fold to a budget and return the reduced messages (this is what agent runs call)
#   $messages | context apply --budget 900000
#
# design notes
# ────────
# 1. **the original is never discarded**. folding only alters the copy that goes
#    out; the full body stays in $nu.data-dir/context/<entry>.json, showable anytime.
#
# 2. **tool turns must always be folded as a pair**. anthropic requires every
#    tool_result to match a tool_use on some earlier assistant message, and
#    folding only half gets the request rejected. so the unit is the "turn":
#    an assistant with tool_use folds with the user message holding its tool_result.
#
# 3. **the budget is an estimate** (chars/3, a conservative midpoint for mixed
#    cjk/latin text). the real number is usage.input_tokens from the api — agent
#    runs use both: real tokens normally, the error's number when overflowing.

const DIR_NAME = "context"
# the model window behind this gateway is 1048576 tokens (per an observed
# error message), so leave 15% headroom by default
const DEFAULT_BUDGET = 890_000
# fold threshold. the placeholder is ~100 chars itself, so folding a smaller
# message only grows it — that gives "always folding, never within budget", and
# ends with the whole context folded away for nothing. only fold clearly bigger ones.
const MIN_FOLD_CHARS = 300

# ── storage ──

def store-dir []: nothing -> path {
  # NU_CONTEXT_DIR overrides the store location — for test isolation, or a store per project
  let override = ($env.NU_CONTEXT_DIR? | default "")
  if ($override | is-empty) {
    $nu.data-dir | path join $DIR_NAME
  } else {
    $override | path expand
  }
}

def entry-path [id: string]: nothing -> path {
  store-dir | path join $"($id).json"
}

def load-entry [id: string]: nothing -> record {
  let p = (entry-path $id)
  if not ($p | path exists) {
    error make { msg: $"entry not found: ($id). run context list to see what exists" }
  }
  open $p
}

def next-id []: nothing -> string {
  let stamp = (date now | format date '%Y%m%d-%H%M%S')
  let rand = (random int 1000..9999)
  $"ctx-($stamp)-($rand)"
}

# ── message helpers ──

def is-blocks [c: any]: nothing -> bool {
  let d = ($c | describe)
  ($d | str starts-with "list") or ($d | str starts-with "table")
}

# does this message hold a block of some kind (only meaningful when content is a block list)
def has-block [m: record, kind: string]: nothing -> bool {
  let c = ($m | get --optional content)
  if $c == null { return false }
  if not (is-blocks $c) { return false }
  $c | any {|b| (($b | describe) | str starts-with "record") and (($b | get --optional type) == $kind) }
}

def char-size [m: record]: nothing -> int {
  ($m | to json -r | str length)
}

# chars → token estimate. /3 is the conservative value for mixed cjk/latin text
def est-tokens [chars: int]: nothing -> int {
  ($chars / 3) | math ceil
}

def role-of [m: record]: nothing -> string {
  ($m | get --optional role | default "?")
}

def placeholder [m: record, idx: int, entry: string, chars: int, kind: string]: nothing -> string {
  let what = (
    if $kind == "tool_pair" { "tool turn\(call + result\)" }
    else if $kind == "tool_use" { "assistant message\(with tool call\)" }
    else if $kind == "tool_result" { "tool result" }
    else { "message" }
  )
  $"[folded] item ($idx) \((role-of $m)) ($what) —— original ($chars) chars, full content in entry ($entry)"
}

# ── policy ──

# build a fold plan: oldest to newest, fold whatever can be folded, until the estimate fits the budget
def plan-fold [
  messages: list
  keep: list<int>
  keep_recent: int
  budget: int
]: nothing -> list<int> {
  let n = ($messages | length)
  let sizes = ($messages | each {|m| char-size $m })
  mut chars = ($sizes | math sum)
  mut plan = []

  let recent_start = ($n - $keep_recent)

  for i in 0..<$n {
    if $chars <= ($budget * 3) { break }
    if ($keep | any {|k| $k == $i }) { continue }
    if $i >= $recent_start { continue }
    if ($plan | any {|p| $p == $i }) { continue }

    let m = ($messages | get $i)
    # fold a tool turn as one pair: assistant(tool_use) + the user(tool_result) right after it
    if (has-block $m "tool_use") and (($i + 1) < $n) {
      let nxt = ($messages | get ($i + 1))
      if ($keep | any {|k| $k == ($i + 1) }) { continue }
      if ($plan | any {|p| $p == ($i + 1) }) { continue }
      if not (has-block $nxt "tool_result") { continue }
      let pair_chars = (($sizes | get $i) + ($sizes | get ($i + 1)))
      if $pair_chars < $MIN_FOLD_CHARS { continue }
      $plan = ($plan | append $i | append ($i + 1))
      $chars = ($chars - $pair_chars)
    } else {
      if ($sizes | get $i) < $MIN_FOLD_CHARS { continue }
      $plan = ($plan | append $i)
      $chars = ($chars - ($sizes | get $i))
    }
  }
  $plan | sort
}

# complete a set of indexes into "legal fold units".
#
# an assistant with tool_use must fold together with the tool_result that follows
# it, and vice versa — half a pair leaves an orphan reference and anthropic
# rejects the entire request. automatic budget planning already pairs them, but
# **manual --fold bypasses that logic**, so explicit indexes pass through here too.
def close-pairs [messages: list, idx: list<int>]: nothing -> list<int> {
  let n = ($messages | length)
  mut out = ($idx | uniq)
  for i in ($idx | uniq) {
    if ($i < 0) or ($i >= $n) { continue }
    let c = (($messages | get $i) | get --optional content)
    let blocks = (if ($c != null) and (is-blocks $c) { $c } else { [] })
    let has_use = ($blocks | any {|b| ($b | get --optional type) == "tool_use" })
    let has_res = ($blocks | any {|b| ($b | get --optional type) == "tool_result" })
    if $has_use and (($i + 1) < $n) {
      $out = ($out | append ($i + 1))
    }
    if $has_res and ($i > 0) {
      $out = ($out | append ($i - 1))
    }
  }
  $out | uniq | sort
}

# ── public commands ──

# record a full context into storage, returning the entry id and how to view it
export def capture [
  --note: string        # a note, so you can recognize it later
]: list -> record {
  let messages = $in
  let id = (next-id)
  let p = (entry-path $id)
  mkdir (store-dir)
  {
    id: $id
    created: ((date now) | format date '%Y-%m-%d %H:%M:%S')
    note: ($note | default "")
    messages: $messages
    folded: []
    kept: []
  } | save -f $p
  {
    entry: $id
    messages: ($messages | length)
    chars: ($messages | to json -r | str length)
    est_tokens: (est-tokens ($messages | to json -r | str length))
    file: ($p | into string)
    view: $"context show ($id)"
  }
}

# list every entry
export def list []: nothing -> table {
  let dir = (store-dir)
  if not ($dir | path exists) { return ([[entry created note messages folded] ]) }
  let files = (glob ($dir | path join "*.json"))
  if ($files | is-empty) { return ([[entry created note messages folded] ]) }
  $files
  | each {|f|
      let e = (open $f)
      {
        entry: ($e | get --optional id | default ($f | path parse | get stem))
        created: ($e | get --optional created | default "")
        note: ($e | get --optional note | default "")
        messages: (($e | get --optional messages | default []) | length)
        folded: (($e | get --optional folded | default []) | length)
      }
    }
  | sort-by created
}

# view an entry. default is an index overview; --index shows one raw message; --full dumps everything
export def show [
  id: string
  --index (-i): int      # show the full raw text of one message
  --full                 # dump everything
  --limit (-l): int = 40 # how many entries the overview lists at most
]: nothing -> any {
  let e = (load-entry $id)
  let msgs = ($e.messages | default [])

  if $full { return $e }

  if $index != null {
    if $index < 0 or $index >= ($msgs | length) {
      error make { msg: $"index out of range: ($index), valid range 0..(($msgs | length) - 1)" }
    }
    return ($msgs | get $index)
  }

  {
    entry: $e.id
    created: ($e | get --optional created | default "")
    note: ($e | get --optional note | default "")
    total: ($msgs | length)
    folded: ($e | get --optional folded | default [])
    kept: ($e | get --optional kept | default [])
  } | print -e   # the overview goes to stderr: otherwise show $id | to json would mix it in

  $msgs
  | enumerate
  | first $limit
  | each {|r|
      let m = $r.item
      let c = ($m | get --optional content)
      let kind = (
        if (has-block $m "tool_use") { "tool_use" }
        else if (has-block $m "tool_result") { "tool_result" }
        else if (is-blocks $c) { "blocks" }
        else { "text" }
      )
      let size = (char-size $m)
      let preview = (
        if (is-blocks $c) { $"($c | length) blocks" }
        else { ($c | into string | str substring 0..( [ 60 ($c | into string | str length) ] | math min )) }
      )
      {
        i: $r.index
        role: (role-of $m)
        kind: $kind
        chars: $size
        preview: $preview
      }
    }
}

# mark some indexes as "folded" (records policy only, never touches the original)
export def fold [id: string, ...idx: int]: nothing -> string {
  let e = (load-entry $id)
  if ($idx | is-empty) { error make { msg: "at least one index is required" } }
  let merged = (($e.folded? | default []) | append $idx | uniq | sort)
  $e | upsert folded $merged | save -f (entry-path $id)
  $"entry ($id):folded ($merged | length) items"
}

# mark some indexes as "kept" (never folded by policy)
export def keep [id: string, ...idx: int]: nothing -> string {
  let e = (load-entry $id)
  if ($idx | is-empty) { error make { msg: "at least one index is required" } }
  let merged = (($e.kept? | default []) | append $idx | uniq | sort)
  $e | upsert kept $merged | save -f (entry-path $id)
  $"entry ($id):kept ($merged | length) items"
}

# delete one entry
export def forget [id: string]: nothing -> string {
  let p = (entry-path $id)
  if not ($p | path exists) { error make { msg: $"entry not found: ($id)" } }
  rm -f $p
  $"deleted entry ($id)"
}

# fold to a budget, returning the reduced messages + entry. this is the entry point agent runs call.
#
# --keep and --fold are policy arguments: the former lists indexes never to fold, the latter ones to force.
# with neither, the default policy applies: protect message 0 (the original task) and the recent few, folding the middle.
#
# three soft constraints worth knowing:
#   - the budget is a **soft target**. protected messages, and those smaller than
#     MIN_FOLD_CHARS, are left alone, so after_tokens may still top --budget. read
#     before_tokens / after_tokens in the result to see the actual effect.
#   - keep-recent is soft too: folding a tool turn folds its partner half as well,
#     even when that half falls inside the "recent" window (pair integrity beats recency).
#   - indexes given to --fold are auto-completed into legal fold units (an assistant
#     with tool_use folds with its tool_result), never splitting a tool turn.
export def apply [
  --budget: int = $DEFAULT_BUDGET   # target estimated tokens
  --keep: list<int> = []            # indexes that must never be folded
  --fold: list<int> = []            # indexes to force-fold (takes priority over the budget)
  --keep-recent: int = 4            # the most recent this many messages are never folded
  --note: string
  --dry-run                         # report the plan only, write nothing to storage
]: list -> record {
  let messages = $in
  let n = ($messages | length)
  let chars = ($messages | to json -r | str length)
  let before_tokens = (est-tokens $chars)

  if $n == 0 {
    return {messages: $messages, entry: null, folded: [], before_tokens: 0, after_tokens: 0, changed: false}
  }

  # message 0 is never folded by default — it is the original task/instruction, and folding it removes the question.
  # (bitten once: with keep_recent set, message 0 lost its protection, so only the task got folded while
  #  the 3MB tool result that actually ate the space was protected as "recent" — the priority was exactly backwards.)
  # an explicit --fold 0 overrides this default.
  let keep = (
    if ($fold | any {|i| $i == 0 }) {
      $keep
    } else {
      ($keep | append 0 | uniq | sort)
    }
  )

  # forced folds win, then the budget fills in the rest.
  # explicit indexes have to go through close-pairs — otherwise a manual --fold splits
  # tool turns and produces a message sequence anthropic rejects outright (confirmed live).
  let in_range = (close-pairs $messages ($fold | where {|i| ($i >= 0) and ($i < $n) }))
  let plan = (
    if ($in_range | is-not-empty) {
      ($in_range | append (
        plan-fold $messages $keep $keep_recent $budget
      ) | uniq | sort)
    } else {
      plan-fold $messages $keep $keep_recent $budget
    }
  )
  # forced folds still cannot touch anything in keep
  let plan = ($plan | where {|i| $keep | all {|k| $k != $i } })

  if ($plan | is-empty) {
    return {
      messages: $messages, entry: null, folded: [], plan: []
      before_tokens: $before_tokens, after_tokens: $before_tokens, changed: false
    }
  }

  let entry = (if $dry_run { null } else {
      $messages | capture --note ($note | default $"auto-fold \(original ($n) msgs / ~($before_tokens) tokens\)") | get entry
    })
  let entry = (if $entry == null { "dry-run" } else { $entry })

  let reduced = ($messages | enumerate | each {|r|
      if ($plan | any {|p| $p == $r.index }) {
        let m = $r.item
        let kind = (
          if (has-block $m "tool_use") { "tool_pair" }
          else if (has-block $m "tool_result") { "tool_result" }
          else { "msg" }
        )
        {role: (role-of $m), content: (placeholder $m $r.index $entry (char-size $m) $kind)}
      } else {
        $r.item
      }
    })

  let after_chars = ($reduced | to json -r | str length)

  # record what was folded this time, so a later show can report it
  if (not $dry_run) and ($entry != "dry-run") {
    let e = (load-entry $entry)
    $e | upsert folded $plan | save -f (entry-path $entry)
  }

  {
    messages: $reduced
    entry: (if $entry == "dry-run" { null } else { $entry })
    folded: $plan
    before_tokens: $before_tokens
    after_tokens: (est-tokens $after_chars)
    changed: true
  }
}
