# host.nu — host/container registry + remote transport layer
#
#   use host.nu
#
#   host add prod --ssh user@prod.example.com
#   host add db   --ssh user@db.internal --jump bastion --port 2222
#   host add pg   --docker pg --via prod          # then into a container on the jump host
#   host list
#   host ping prod
#   host exec prod "uname -a"
#   host sync prod
#
# read / write / bash reuse this layer too (each adds --host).
#
# ── security model: the registry is the allowlist ──
# only names registered via `host add` can be used as a host; anything
# unregistered is refused. one place governs every tool's remote reach.
#
# ── quoting model (critical, don't get it wrong) ──
# two kinds of things, keep them apart:
#
#   1. the command itself — passed through raw as one argv element, unquoted.
#      the remote shell parsing it is **intended behavior** — it is the shell command
#      to be executed. if you sh-quote the whole command, the shell takes the whole
#      string as one word, so `echo a; echo b` becomes "command not found: echo a; echo b".
#
#   2. data embedded in the command string (paths, container names) — must be sh-quoted.
#      otherwise a `;` `$(...)` or backtick in a path gets executed as code by the remote shell.
#
# remote commands are uniformly wrapped in `sh -c '<cmd>'`: forces POSIX sh, unaffected
# by the remote login shell (some servers use csh, where the syntax differs).
#
# sh-quote was verified against adversarial input: single quotes, semicolons, backticks,
# $(...), newlines all round-trip byte for byte; controls proved injection without it.

use ../core/quote.nu
use ../core/layout.nu

const CFG_NAME = "hosts.json"
const DEFAULT_READ_MAX = 200_000

# registry path. NU_HOST_CONFIG can point it elsewhere — handy for test
# isolation, or to give one project its own host list.
def cfg-path []: nothing -> path {
  let override = ($env.NU_HOST_CONFIG? | default "")
  if ($override | is-empty) {
    $nu.default-config-dir | path join $CFG_NAME
  } else {
    $override | path expand
  }
}

def load-hosts []: nothing -> record {
  let p = (cfg-path)
  if not ($p | path exists) { {} } else { open $p }
}

def save-hosts [h: record]: nothing -> nothing {
  $h | save -f (cfg-path)
  null
}


# allowlist gate: only registered names get through
def resolve [name: string]: nothing -> record {
  let h = (load-hosts)
  let names = ($h | columns)
  if not ($names | any {|c| $c == $name }) {
    let hint = (
      if ($names | is-empty) {
        "no hosts registered yet — add one first with host add"
      } else {
        $"registered: ($names | str join ', ')"
      }
    )
    error make { msg: $"unregistered host: ($name). ($hint)" }
  }
  $h | get $name
}

# wrap a command string into a directly executable argv.
# returns argv rather than a string — no shell involved at this layer, one less quoting problem.
def wrap [rec: record, command: string]: nothing -> list<string> {
  let kind = ($rec | get --optional type | default "ssh")

  if $kind == "docker" {
    let container = ($rec | get --optional container)
    if $container == null {
      error make { msg: "docker host is missing the container field" }
    }
    let shell = ($rec | get --optional shell | default "bash")
    let via = ($rec | get --optional via)
    let user = ($rec | get --optional user)

    # some containers only let root write to directories (measured: in one sandbox
    # image the agent user couldn't write even /tmp; only root inside could write and
    # execute). these need -u, otherwise you can't even put anything into the container.
    let uflag = (if $user == null { [] } else { ["-u", ($user | into string)] })

    if $via == null {
      # local docker: docker exec takes argv straight through, so the inner command needs no quoting
      ["docker", "exec", "-i"] | append $uflag | append [$container, $shell, "-c", $command]
    } else {
      # into a container on a jump host: the inner part is handed to the remote sh
      # to parse, so the container name and the command both go through sh-quote
      let uq = (if $user == null { "" } else { $"-u (quote sh ($user | into string)) " })
      let inner = $"docker exec -i ($uq)(quote sh $container) (quote sh $shell) -c (quote sh $command)"
      wrap (resolve $via) $inner
    }
  } else {
    let target = ($rec | get --optional target)
    if $target == null {
      error make { msg: "ssh host is missing the target field" }
    }
    let port = ($rec | get --optional port)
    let jump = ($rec | get --optional jump | default [])

    # multi-hop goes through OpenSSH's native -J a,b rather than nesting ssh layers
    let opts = (
      ["-T"]
      | append (if $port == null { [] } else { ["-p", ($port | into string)] })
      | append (if ($jump | is-empty) { [] } else { ["-J", ($jump | str join ",")] })
    )
    ["ssh"] | append $opts | append [$target, "sh", "-c", (quote sh $command)]
  }
}

# scan an ssh config and collect concrete Host aliases.
#
# wildcard patterns (* ? !) are skipped — they are "rules", not concrete hosts.
# only host lines count; other directives in a Match block are not mistaken for a Host.
#
# note: never split this line with `split words` — it eats punctuation, so
# "Host *.internal" becomes ["Host","internal"] and wildcard detection breaks.
# normalize whitespace first, then split row.
def parse-ssh-config [text: string]: nothing -> list<string> {
  mut names = []
  for line in ($text | lines) {
    let l = ($line | str trim)
    if ($l | is-empty) or ($l | str starts-with "#") { continue }
    let words = ($l | str replace -r -a '\s+' ' ' | split row ' ')
    if (($words | first | str lowercase) != "host") { continue }
    for pat in ($words | skip 1) {
      let wildcard = (($pat | str contains "*") or ($pat | str contains "?") or ($pat | str contains "!"))
      if not $wildcard {
        $names = ($names | append $pat)
      }
    }
  }
  $names | uniq
}

# register a host
export def add [
  name: string          # alias; this is what you pass to --host later
  --ssh: string         # ssh target, e.g. user@host or a Host name from ssh config
  --docker: string      # container name
  --jump: string        # jump host(s), comma-separated: bastion,relay (ssh only)
  --port: int           # ssh port (ssh only)
  --shell: string       # shell inside the container, defaults to bash (docker only)
  --via: string         # run docker on this already-registered host (docker only)
  --user: string        # docker exec -u, enter the container as this user (docker only)
]: nothing -> string {
  if ($ssh | is-empty) and ($docker | is-empty) {
    error make { msg: "you must give either --ssh or --docker" }
  }
  if ($ssh | is-not-empty) and ($docker | is-not-empty) {
    error make { msg: "--ssh and --docker are mutually exclusive" }
  }
  if ($ssh | is-not-empty) and ($via | is-not-empty) {
    error make { msg: "--via only makes sense with --docker" }
  }

  # --via must resolve at registration time, so a typo surfaces now rather than at use time
  if ($via | is-not-empty) {
    let _ = (resolve $via)
  }

  let rec = (
    if ($ssh | is-not-empty) {
      {type: "ssh", target: $ssh}
      | if $port == null { $in } else { insert port $port }
      | if ($jump | is-empty) { $in } else { insert jump ($jump | split row ',') }
    } else {
      {type: "docker", container: $docker}
      | if ($shell | is-empty) { $in } else { insert shell $shell }
      | if ($via | is-empty) { $in } else { insert via $via }
      | if ($user | is-empty) { $in } else { insert user $user }
    }
  )

  let h = (load-hosts)
  let existed = (($h | columns) | any {|c| $c == $name })
  save-hosts (if $existed { $h | upsert $name $rec } else { $h | insert $name $rec })
  let verb = (if $existed { "updated" } else { "registered" })
  $"($verb) host ($name): ($rec | to json -r)"
}

# list every registered host
export def list []: nothing -> table {
  let h = (load-hosts)
  if ($h | columns | is-empty) {
    # use a table literal, not [ [...] | append [...] ] — nu misparses that form
    return ([[name type target]; ["(none)" "-" "no hosts registered yet"]] | rename name type target)
  }
  $h
  | transpose name rec
  | each {|r|
      let t = ($r.rec.type? | default "?")
      let where = (
        if $t == "docker" {
          let via = ($r.rec.via? | default null)
          if $via == null { $"container:($r.rec.container?)" } else { $"($via) → container:($r.rec.container?)" }
        } else {
          let jump = ($r.rec.jump? | default [])
          let p = ($r.rec.port? | default null)
          let base = ($r.rec.target? | default "?")
          let withport = (if $p == null { $base } else { $"($base):($p)" })
          if ($jump | is-empty) { $withport } else { $"($jump | str join ',') → ($withport)" }
        }
      )
      {name: $r.name, type: $t, target: $where}
    }
}

# show the raw record of one host
export def show [name: string]: nothing -> record {
  resolve $name
}

# delete a host
export def remove [name: string]: nothing -> string {
  let h = (load-hosts)
  if not (($h | columns) | any {|c| $c == $name }) {
    error make { msg: $"unregistered host: ($name)" }
  }
  save-hosts ($h | reject $name)
  $"deleted host ($name)"
}

# connectivity check
export def ping [name: string]: nothing -> string {
  let r = (exec $name "echo ok; uname -s 2>/dev/null || true")
  if $r.exit_code != 0 {
    error make { msg: $"cannot reach ($name): ($r.stderr | str trim)" }
  }
  $"($name) reachable: ($r.stdout | str trim | str replace -a (char nl) ' ')"
}

# run one command on the target, returns {exit_code, stdout, stderr}
export def exec [
  name: string          # registered host name
  command: string       # shell command (parsed by sh on the remote side)
  --stdin: string       # stdin to feed the command
  --cwd: path           # working directory
  --dry-run             # only print the argv that would run, don't actually run it
]: nothing -> any {
  let rec = (resolve $name)

  # cwd is joined with a newline, not && — the command may span lines, and && would only affect the first
  let full = (
    if $cwd == null {
      $command
    } else {
      $"cd (quote sh ($cwd | into string)) || exit 1\n($command)"
    }
  )

  let argv = (wrap $rec $full)
  if $dry_run { return $argv }

  let cmd = ($argv | first)
  let args = ($argv | skip 1)

  try {
    if $stdin == null {
      run-external $cmd ...$args | complete
    } else {
      $stdin | run-external $cmd ...$args | complete
    }
  } catch {|e|
    error make { msg: $"running ($cmd) failed: ($e.msg)" }
  }
}

# read a remote text file. anything non-text errors out, so garbage never lands in context
export def fetch [
  name: string
  path: path
  --max-bytes: int = $DEFAULT_READ_MAX   # refuse anything larger
]: nothing -> string {
  # fetch only max+1 bytes: saves a round trip, and avoids the race between "check size, then read"
  let cmd = $"head -c ($max_bytes + 1) -- (quote sh ($path | into string))"
  let r = (exec $name $cmd)

  if $r.exit_code != 0 {
    error make { msg: $"reading ($path) failed: ($r.stderr | str trim)" }
  }

  let got = ($r.stdout)
  if ($got | str length) > $max_bytes {
    error make { msg: $"($path) is over ($max_bytes) bytes. raise the limit with --max-bytes" }
  }
  $got
}

# write a remote file (content verbatim, no trailing newline added — measured: nu pipelines don't sneak one in)
export def put [
  name: string
  path: path
  content: string
]: nothing -> nothing {
  let cmd = $"cat > (quote sh ($path | into string))"
  let r = (exec $name $cmd --stdin $content)
  if $r.exit_code != 0 {
    error make { msg: $"writing ($path) failed: ($r.stderr | str trim)" }
  }
  null
}

# check whether a remote path exists (-e holds for both files and directories)
export def exists [
  name: string
  path: path
]: nothing -> bool {
  let r = (exec $name $"test -e (quote sh ($path | into string))")
  $r.exit_code == 0
}

# bulk-import Host entries from an ssh config
#
#   host import                    # import every concrete Host in ~/.ssh/config
#   host import --dry-run          # preview what would be imported first
#   host import --only a,b         # import only the named ones
#   host import --prefix s-        # prefix registered names so they don't collide with existing entries
#
# target stores the ssh config **alias** itself, not the resolved HostName —
# that way ssh applies HostName / User / Port / IdentityFile / ProxyJump and all
# the rest of the config itself. any cascading jump setup you already wrote in
# config therefore applies automatically, with no --jump needed here.
export def import [
  --file: path = "~/.ssh/config"   # ssh config file to import from
  --only: string                   # import only these, comma-separated
  --prefix: string                 # prefix for registered names
  --force                          # overwrite already-registered entries of the same name
  --dry-run                        # only report what would happen, don't write the registry
]: nothing -> any {
  let p = ($file | path expand)
  if not ($p | path exists) {
    error make { msg: $"ssh config file not found: ($p)" }
  }

  let text = (open --raw $p | into string)
  let all = (parse-ssh-config $text)
  if ($all | is-empty) {
    error make { msg: $"no concrete Host entries in ($p) \(wildcards and Match are skipped\)" }
  }

  let wanted = (
    if $only == null {
      $all
    } else {
      let want = ($only | split row ',')
      $all | where {|n| $want | any {|w| $w == $n } }
    }
  )
  if ($wanted | is-empty) {
    error make { msg: $"--only matched no Host. config contains: ($all | str join ', ')" }
  }

  let items = ($wanted | each {|a|
      {name: (if $prefix == null { $a } else { $"($prefix)($a)" }), alias: $a}
    })

  let existing = (load-hosts | columns)
  let fresh = ($items | where {|i| $existing | all {|e| $e != $i.name } })
  let dup = ($items | where {|i| $existing | any {|e| $e == $i.name } })

  if $dry_run {
    return {
      file: ($p | into string)
      hosts_in_config: ($all | length)
      will_add: ($fresh | get name)
      already_registered: ($dup | get name)
    }
  }

  mut h = (load-hosts)
  for i in $fresh {
    $h = ($h | upsert $i.name {type: "ssh", target: $i.alias})
  }
  if $force {
    for i in $dup {
      $h = ($h | upsert $i.name {type: "ssh", target: $i.alias})
    }
  }
  save-hosts $h

  let overwritten = (if $force { $dup | length } else { 0 })
  let note = (
    if (not $force) and (($dup | length) > 0) {
      $", skipped ($dup | length) already registered \(add --force to overwrite\)"
    } else {
      ""
    }
  )
  $"read ($all | length) Hosts from ($p): ($fresh | length) added, ($overwritten) overwritten($note)"
}

# push local nu modules to the remote
export def sync [
  name: string
  --dir: string         # remote directory, defaults to $HOME/.nu-modules
  --configure           # also append use lines to the remote config.nu (modifies remote config)
]: nothing -> string {
  # ~ can't be sh-quoted directly (no expansion inside single quotes), so ask the remote for $HOME first
  let remote_dir = (
    if ($dir | is-not-empty) {
      $dir
    } else {
      let r = (exec $name "printf '%s' \"$HOME\"")
      if $r.exit_code != 0 {
        error make { msg: $"could not get remote HOME: ($r.stderr | str trim)" }
      }
      $"($r.stdout | str trim)/.nu-modules"
    }
  )

  let r = (exec $name $"mkdir -p (quote sh $remote_dir)")
  if $r.exit_code != 0 {
    error make { msg: $"failed to create directory: ($r.stderr | str trim)" }
  }

  # the module set is this checkout's core/ and tools/ trees — not the config
  # dir, which no longer holds them. both directories are flat, so one glob each.
  # glob takes a positional argument and does not accept pipeline input.
  let root = (layout root)
  let files = (
    [(glob ($root | path join "core/*.nu")) (glob ($root | path join "tools/*.nu"))]
    | flatten
    | sort
  )
  if ($files | is-empty) {
    error make { msg: "no local .nu modules available to sync" }
  }

  let pushed = ($files | each {|f|
      let base = ($f | path basename)
      put $name $"($remote_dir)/($base)" (open --raw $f)
      $base
    })

  let advice = $"already placed at ($remote_dir) on the remote. in remote nu: use \(($remote_dir)/read.nu\) etc"

  if not $configure {
    return $"synced ($pushed | length) modules to ($name):($remote_dir)\n($advice)\nremote config untouched \(pass --configure to append use lines\)"
  }

  # --configure: append the use lines to the remote config.nu
  let probe = (exec $name "nu -c 'print $nu.default-config-dir'")
  if $probe.exit_code != 0 {
    error make { msg: $"no usable nu on the remote, cannot --configure: ($probe.stderr | str trim)" }
  }
  let remote_cfg_dir = ($probe.stdout | str trim)
  let cfg = $"($remote_cfg_dir)/config.nu"

  let lines = (
    $pushed
    | where {|f| $f != "config.nu" }
    | each {|f| $"use \(($remote_dir)/($f)\)" }
    | str join (char nl)
  )

  let existing = (try { fetch $name $cfg --max-bytes 2_000_000 } catch { "" })
  let marker = "# ── appended by host sync ──"
  let body = $"($existing)\n($marker)\n($lines)\n"
  put $name $cfg $body

  $"synced ($pushed | length) modules to ($name):($remote_dir)\nappended use lines to ($cfg)"
}
