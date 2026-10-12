# peers.nu — read-only enumeration of the AI agent processes running on this machine and their sessions
#
#   use peers.nu
#   peers list
#   peers list --kind claude
#   peers cwd [1234 5678]
#   peers sessions --per-dir 2
#
# why a separate module: `agent` spawns a child process for each tool call with no
# permission confirmation. handing bash to a child agent hands over the whole machine.
# this module only enumerates processes and extracts read-only fields, and **accepts no arbitrary command string**, so it is safe to lend out.
#
# ── why the exported commands return JSON strings instead of tables ──
# nu truncates table columns to the terminal width, so long fields become `...`.
# measured: in a 3893-character output 9 lines were cut and a whole column
# (first_prompt) vanished —— the child agent then reported it could not tell
# what each agent was doing. these commands are called by an LLM, so output must
# be lossless: exports always to json -r. cost: no piping in nu (internal calls use the private functions below).
#
# ── gotchas actually hit (do not repeat them) ──
#   · a line starting with `and` is treated as an external command (expose.nu:70 has the same warning)
#   · flatten over a list of records flattens the records apart (agent.nu:383)
#   · ls "path/*.jsonl" does not glob —— double quotes are literal, use glob
#   · $f.size is a filesize, it cannot be fed straight to math round
#   · after try/catch, compact swallows the error into an empty table —— an empty table and "none" look identical

const KINDS = ["claude" "codex" "cline" "aider" "copilot" "ollama" "goose"]

# basename of argv[0]. both "claude" and "/Users/x/.local/bin/claude" classify as claude
def exe-name [args: string]: nothing -> string {
  let first = ($args | str trim | split row ' ' | first)
  try { $first | path basename } catch { $first }
}

def classify [args: string]: nothing -> string {
  let e = (exe-name $args)
  $KINDS | where {|k| $e | str contains $k } | first | default "other"
}

# ── private: the process table. exported commands never use it directly, so the table never gets column-truncated ──

def proc-table []: nothing -> table {
  ^ps -Ao pid=,ppid=,etime=,args=
  | lines
  | each {|l|
      let t = ($l | str trim)
      if ($t | is-empty) { return null }
      # do not use split row: ps is column-aligned output, so runs of spaces split into a string of empty strings.
      # measured: `split row -n 4 ' '` on "614     1 01-08:56:49 /System/..."
      # splits ppid into "", and into int errors out immediately.
      let p = ($t | parse -r '^(?<pid>\d+)\s+(?<ppid>\d+)\s+(?<elapsed>\S+)\s+(?<args>.*)$')
      if ($p | is-empty) { return null }
      let r = ($p | first)
      {
        pid: ($r.pid | into int)
        ppid: ($r.ppid | into int)
        elapsed: $r.elapsed
        kind: (classify $r.args)
        args: (if ($r.args | str length) > 160 { $r.args | str substring 0..160 } else { $r.args })
      }
    }
  | compact
}

# batch working-directory lookup. takes a pid list instead of a single pid: each `agent`
# tool call is a whole API round trip, so one-at-a-time turns 27 processes into 27 rounds. hand them all over at once, one round total.
def cwd-table [pids: list<int>]: nothing -> table {
  if ($pids | is-empty) { return [] }
  let joined = ($pids | each {|p| $p | into string } | str join ',')
  let r = (^lsof -a -p $joined -d cwd -Fn | complete)
  if $r.exit_code != 0 {
    error make { msg: $"lsof failed: ($r.stderr | str trim). a pid may have exited" }
  }
  # lsof -Fn output is alternating lines of p<pid> / n<path>
  $r.stdout
  | lines
  | reduce --fold {cur: 0, out: []} {|line, acc|
      if ($line | str starts-with 'p') {
        {cur: ($line | str substring 1.. | into int), out: $acc.out}
      } else if ($line | str starts-with 'n') {
        {cur: $acc.cur, out: ($acc.out | append {pid: $acc.cur, cwd: ($line | str substring 1..)})}
      } else { $acc }
    }
  | get out
}

# ── session layer ──
# transcripts live in ~/.claude/projects/<slug>/<session-id>.jsonl, where slug is the cwd with
# both `/` and `.` replaced by `-` (measured: /Users/user/.openrig/workspace →
# -Users-user--openrig-workspace).
#
# extract summaries only, never the body: a single jsonl can reach 167MB, and feeding
# the text straight to a child agent burns the whole context instantly. here each session returns only a few scalar fields.

# pull plain text out of a message. content may be a string, or a list of blocks
def msg-text [m: any]: nothing -> string {
  if $m == null { return "" }
  let c = ($m | get --optional content)
  if $c == null { return "" }
  if (($c | describe) | str starts-with 'string') { return $c }
  if (($c | describe) | str starts-with 'list') {
    let t = ($c | where {|b| ($b | get --optional type) == "text" } | get --optional text | first)
    return ($t | default "")
  }
  ""
}

def session-info [f: record, cwd: string, prompt_chars: int]: nothing -> record {
  let path = ($f.name | into string)
  let id = ($path | path basename | str replace -a '.jsonl' '')

  # first genuine user instruction: skip meta lines, and skip sidechains (a child agent's session).
  # split into several where clauses instead of chaining with and —— a line starting
  # with `and` in nu is treated as an external command (measured "Command `and` not found", see the warning at expose.nu:70).
  let first_user = (
    ^head -n 300 $path
    | lines
    | each {|l| try { $l | from json } catch { null } }
    | compact
    | where {|r| ($r | get --optional type) == "user" }
    | where {|r| not ($r | get --optional isSidechain | default false) }
    | where {|r| (msg-text ($r | get --optional message)) | is-not-empty }
    | first
  )

  let last = (
    ^tail -n 20 $path
    | lines
    | each {|l| try { $l | from json } catch { null } }
    | compact
    | last
  )

  let prompt = (
    if $first_user == null { "" } else {
      let t = (msg-text ($first_user | get --optional message))
      if ($t | str length) > $prompt_chars { $t | str substring 0..$prompt_chars } else { $t }
    }
  )

  {
    id: ($id | str substring 0..8)
    cwd: $cwd
    age_min: ((((date now) - $f.modified) / 1min) | math round --precision 1)
    mb: (($f.size / 1mb) | math round --precision 2)
    lines: (^wc -l $path | str trim | split row ' ' | first | into int)
    branch: ($last | get --optional gitBranch | default "")
    last_type: ($last | get --optional type | default "")
    last_msg: ((msg-text ($last | get --optional message)) | str substring 0..60)
    first_prompt: $prompt
  }
}

# failure row. an empty table looks exactly like "no sessions", so an error must leave a trace.
def err-row [cwd: string, msg: string]: nothing -> record {
  {
    id: "ERR", cwd: $cwd, age_min: 0.0, mb: 0.0, lines: 0,
    branch: "", last_type: "ERROR",
    last_msg: (($msg | lines | first | default "") | str substring 0..120),
    first_prompt: ""
  }
}

# ── public commands (all return JSON strings) ──

# list the agent processes running on this machine, classified by kind.
# each row: pid / ppid / uptime / kind / command line (truncated to 160 chars).
export def list [
  --kind: string    # keep only this kind, e.g. claude / codex / copilot
]: nothing -> string {
  let t = (proc-table)
  if ($kind | is-empty) {
    $t | to json -r
  } else {
    $t | where kind == $kind | to json -r
  }
}

# batch working-directory lookup —— this is basically how you answer "which project is this agent on".
# pass the whole pid list at once, never one by one (each pid is an API round trip).
export def cwd [
  pids: list<int>    # target pid list, taken from agents list
]: nothing -> string {
  cwd-table $pids | to json -r
}

# list the sessions of each running claude agent.
# only the most recent --per-dir sessions per working directory (agents sharing a cwd see the same batch).
# age_min is minutes since the last write —— that is what tells you whether it is alive.
export def sessions [
  --per-dir: int = 2        # max sessions to return per working directory, sorted by most recent activity
  --prompt-chars: int = 70  # truncation length for the first user instruction
]: nothing -> string {
  let procs = (proc-table | where kind == "claude")
  if ($procs | is-empty) { return "[]" }

  let cwds = (cwd-table ($procs | get pid))
  if ($cwds | is-empty) { return "[]" }
  let dirs = ($cwds | get cwd | uniq)

  $dirs
  | each {|cwd|
      let slug = ($cwd | str replace -a '/' '-' | str replace -a '.' '-')
      let pdir = ($"($env.HOME)/.claude/projects/($slug)")
      if not ($pdir | path exists) { return [] }
      # cannot use ls "path/*.jsonl": double-quoted strings in nu are literal and do not glob
      # (measured: DoNotExpand / no matches found). glob is the explicit expansion.
      let files = (try { glob $"($pdir)/*.jsonl" } catch { [] })
      if ($files | is-empty) { return [] }
      # must use the spread operator ls ...$files, not ls each file then flatten ——
      # nu's flatten recurses into records and flattens apart the rows ls returns (see agent.nu:383).
      # it happened once: $f.name became a list<string> and everything downstream blew up.
      ls ...$files
      | sort-by modified --reverse
      | first $per_dir
      | each {|f| try { session-info $f $cwd $prompt_chars } catch {|e| err-row $cwd $e.rendered } }
    }
  | flatten
  | to json -r
}
