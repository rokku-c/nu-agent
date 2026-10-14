# bridge.nu — the agent, behind WeChat
#
#   use bridge.nu
#
#   bridge serve                       # long poll, answer each message with the agent
#   bridge serve --tools [nu-shell market macro] --allow [<a-user-id>]
#
# ── the loop ──
#   long poll → for each message → check the sender → run the agent → reply with the token
#   the message carried
#
# ── the security decision, which is the whole of this file's design ──
# the default tool set here includes `nu-shell`, and that is deliberate: it is what makes the
# agent able to actually do anything. but it also means anyone who can put a message in front
# of this bot can run nushell on this machine. so a sender allowlist is not optional, and it
# defaults to the ONE user bound at login rather than to everyone.
#
# that default is the difference between "my assistant" and "a remote shell for whoever finds
# the bot". widening it is a one-flag decision a person makes on purpose, which is the only
# shape that decision should have.
#
# ── how a reply is sent ──
# the MODEL sends, through the `reply` tool, and decides where the breaks fall. the bridge
# used to answer by pushing the model's final text through `clip`, which cuts at a
# character count — mid-sentence, mid-table — because a character count has no idea where a
# break belongs. `clip` survives only as the fallback for a run that called the tool zero
# times, so a model that ignores the brief still answers instead of going silent.
#
# ── what is not handled yet, said plainly ──
#   · no markdown filter — the official client strips markers before sending, this does not,
#     so a reply full of `**` arrives with the asterisks in it.
#   · no typing indicator, no progress, no media in either direction.
#   · one message at a time: a long agent run blocks the poll, so messages queue up behind it
#     rather than being answered concurrently.
#   · nothing paces `reply`: a model that calls it ten times sends ten messages back to back,
#     and whether Tencent rate-limits that is untested.

use ./ilink.nu
use ../../core/reason.nu
use ../toolset.nu

const LENGTH_CAP = 1800

# how often `serve` says it is still alive, in polls. measured on an idle account: 10 polls
# took 182s, so roughly every 3 minutes — often enough to notice a wedged loop, rare enough
# that a log left running overnight stays readable.
#
# the arithmetic is not 10 × the timeout because the SERVER does not hold a poll that long. it
# answers an empty long poll at about 18s: measured, an 8s timeout blocked 8.17s, a 20s timeout
# 18.32s, and ten idle polls of a 40s timeout averaged 18.2s. so `--timeout` above ~18s changes
# nothing on an idle account, and the comment here is the only place that says so.
const HEARTBEAT_POLLS = 10

# ── what the default set is, plainly ──
# `shell` runs commands, `proc` (tool: exec) runs a program without a shell, `write` and
# `edit` change files, and `nu-shell` evaluates nushell. together they are not "a helpful
# assistant" — they are arbitrary code execution and arbitrary file writes, reachable by a
# chat message. the allowlist below is therefore the ENTIRE security boundary, not a
# courtesy: every name added to it is a person handed this machine.
#
# the set itself lives in toolset.nu and is re-read on every poll, so `/load` and `/unload`
# take effect on the next message rather than at the next restart.

# ── the real reason, not the wrapper ──
# a failure raised inside a closure (`each`, `where`, `reduce`) is wrapped by nu into
# ShellError::EvalBlockWithInput, whose `.msg` is the literal string "Eval block failed
# with pipeline input". reading only `.msg` is what once turned "module not found: calc"
# into a sentence that named nothing — so nothing in this file reports an error without
# going through `reason`, which lives in core/reason.nu.
#
# it moved there when the one-level unwrap this file used to do turned out to be wrong:
# nesting repeats the wrapper, and the cause sits two levels down. the measurement and the
# walk that reaches it are documented in that file.

# the chat gets one line; the LOG gets every message on the way down plus the error record
# and the prompt that caused it. a bridge that reports only into a chat window cannot be
# debugged after the fact, and that is not hypothetical — "Eval block failed with pipeline
# input" survived a full round of fixing precisely because nothing on disk recorded what was
# behind it. the chain is logged in full because the one-line answer is a summary: it drops
# the wrapper and joins the rest, and when that is not enough the raw shape has to be there.
def log-error [prompt: string, e: any]: nothing -> nothing {
  print -e "  !! agent error"
  print -e $"     prompt : ($prompt | str substring 0..120)"
  print -e $"     reason : (reason $e)"
  print -e $"     chain  : (reason chain $e | to json -r)"
  print -e $"     details: ($e | get --optional details | to nuon)"
}

# ── slash commands ──
# these run INSTEAD of the agent, from the same allowlist. they exist because the tool set is
# the thing most worth changing from a phone, and because "which module gives me exec" is a
# question whose answer should not cost an agent turn.
export def slash [text: string]: nothing -> string {
  let parts = ($text | str trim | split row " ")
  let cmd = ($parts | first | str lowercase)
  let args = ($parts | skip 1)

  if $cmd in ["/help" "/?"] {
    return "可用:
/tools              当前工具集
/tools all          所有可加载的模块
/search <词>        按模块名/工具名/描述找
/load <模块...>     加入
/unload <模块...>   移除
/reset              恢复默认"
  }
  if $cmd == "/tools" {
    if ($args | first) == "all" {
      return (toolset available | each {|m| $"($m.module): ($m.tools | str join ', ')" } | str join "
")
    }
    let cur = (toolset show)
    return $"工具集\(($cur.modules | length)):
($cur.modules | str join ', ')

tool: (toolset tools | str join ', ')"
  }
  if $cmd == "/search" {
    if ($args | is-empty) { return "/search <词>" }
    let hits = (toolset search ($args | str join " "))
    if ($hits | is-empty) { return $"没有匹配 ($args | str join ' ')" }
    return ($hits | each {|m| $"($m.module): ($m.tools | str join ', ')" } | str join "
")
  }
  if $cmd == "/load" or $cmd == "/unload" {
    if ($args | is-empty) { return $"($cmd) <模块...>" }
    let r = (try {
      if $cmd == "/load" { toolset load ...$args } else { toolset unload ...$args }
    } catch {|e| {error: ((reason $e) | str substring 0..300)}})
    if ($r | get --optional error) != null { return $"失败: ($r.error)" }
    return $"现在有 ($r.modules | length) 个模块:
($r.modules | str join ', ')"
  }
  if $cmd == "/reset" {
    return $"已恢复默认:((toolset reset | get modules) | str join ', ')"
  }
  $"不认识的命令 ($cmd) —— 发 /help"
}

# ── the fallback cut, and what it actually does ──
# LENGTH_CAP is compared against `str length`, which is BYTES, not characters (measured below).
# for this bot's usual language that makes the effective cap ~600 characters, not 1800.
#
# and `str substring` indexes BYTES too, so the cut lands mid-character and the result carries a
# U+FFFD replacement char: measured, a 900-character Chinese answer comes out as 584 characters
# containing "�". both are real and both are on the path a user sees whenever the model sends
# nothing for itself.
#
# left as-is on purpose rather than quietly changed: counting bytes is the CONSERVATIVE error.
# a cut that is too aggressive still delivers; a cap that is too loose gets the message rejected,
# hits the catch below, and ends as silence — which is the one outcome this fallback exists to
# prevent. so the budget stays, and what is worth fixing is the boundary, not the unit.
def clip [s: string]: nothing -> string {
  if ($s | str length) <= $LENGTH_CAP { $s } else {
    ($s | str substring 0..($LENGTH_CAP - 60)) + "\n\n[被截断: 微信消息有长度上限, 这条回复没有分段发送]"
  }
}

# ── what the model is told ──
# this brief is the entire reason `reply` gets used. without it the model returns text, the
# bridge sends one blob, and a long answer is cut mid-word — which is the behaviour this
# replaced. the last line matters as much as the first: `reply` is a DELIVERY mechanism and
# says nothing about how to work, so the other tools stay in play exactly as before.
const REPLY_BRIEF = "你在微信上回答。回复要用 `reply` 工具发出去——你最后返回的文字不会发给对方。

- 一次 `reply` = 一条微信消息。按意思分段：一个小节、一个想法、一张表，各自成一条。不要为了凑长度去拆。
- 长回答就多发几条，每条自己读得通。宁可多发两条，也不要让一条长到被服务器拒掉。
- 想先说一句再干活也行：先 reply 一句\"我看一下\"，再去查。
- 要算数、要取数据，照常用别的工具；算完再用 reply 说结论。"

# the agent, one turn, with whatever tools were asked for. any failure is returned as TEXT
# rather than raised, because the only place it can go is back to the user in a chat window.
# the failure text goes through `reason`, not `$e.msg`: see the note above `log-error` — the
# wrapper nu puts around a closure-raised error names nothing at all.
def answer [prompt: string, tools: list<string>]: nothing -> string {
  try {
    # `uniq`: /load reply would otherwise put it in the list twice, and two tool definitions
    # with the same name is an API error, not a merge
    let out = (agent $prompt --tools-from ($tools | append "reply" | uniq) --system $REPLY_BRIEF)
    if ($out | describe) == "string" and ($out | is-not-empty) { $out } else { "（agent 没有返回文字）" }
  } catch {|e|
    log-error $prompt $e
    $"agent 出错:\n((reason $e) | str substring 0..600)"
  }
}

# the loop. runs until interrupted, or once with --once (useful for testing a single message).
export def serve [
  --bot-id: string           # which stored WeChat account
  --allow: list<string>      # who may drive it. defaults to the user bound at login — and
                             # every name added here is a person who can run code on this
                             # machine, so it is a grant, not a filter
  --tools: list<string>      # override the stored set for this run only
  --timeout: duration = 40sec   # the server caps an empty poll near 18s, so raising this past
                                # that does nothing — see the note on HEARTBEAT_POLLS
  --once
  --quiet                    # do not print each step
]: nothing -> any {
  let acct = (ilink account --bot-id $bot_id)
  # the default allowlist is the account that was bound, and nothing else. a message from
  # anyone else is answered with a refusal rather than silence, so that a person who expected
  # it to work can see why it did not.
  let allowed = (if ($allow | is-empty) { [$acct.user_id] } else { $allow } | compact)

  if not $quiet {
    # the timestamp matters more than it looks: this process is meant to be run detached with
    # its output redirected to a file, and that file accumulates runs. without a stamp, a log
    # holding three starts and one error cannot say which start the error belongs to — or
    # whether it predates the current process at all. it cost a round of exactly that.
    let started = (date now | format date "%Y-%m-%d %H:%M:%S")
    print $"bridge up  ($started)"
    print $"  bot        ($acct.bot_id)"
    print $"  allowed    ($allowed | str join ', ')"
    let active = (if ($tools | is-empty) { toolset show | get modules } else { $tools })
    print $"  tools      ($active | str join ', ')"
  }

  mut handled = 0
  mut polls = 0
  loop {
    # --dump leaves the server's RAW batch on disk. the parsed shape is already lossy — a
    # message with no text comes through as `text: null` and the interesting part (which
    # item_list kind it was) is gone. when something arrives that this loop cannot act on,
    # the raw form is the only thing that can say what it actually was.
    let batch = ($nu.temp-dir | path join $"nu-agent-wechat-batch-($acct.bot_id).json")
    let r = (ilink updates --once --timeout $timeout --bot-id $bot_id --dump $batch)
    $polls = $polls + 1

    # a heartbeat, every HEARTBEAT_POLLS polls. without it a log with no `in:` line means
    # EITHER "nobody wrote to the bot" OR "the loop is wedged", and those want opposite
    # responses — one is fine, the other is broken. reconstructing which one it was from
    # process CPU time and file mtimes is exactly the guessing this line removes.
    if (not $quiet) and (($polls mod $HEARTBEAT_POLLS) == 0) {
      let t = (date now | format date "%H:%M:%S")
      let got = (($r.messages? | default []) | length)
      print $"  · poll ($polls) at ($t) — ($got) message\(s)"
    }

    for m in ($r.messages? | default []) {
      let text = ($m.text? | default null)
      # emptiness counts, not just nullness: an item_list can carry a text_item whose text is
      # "", and read-message joins those into "". that is not a prompt — handing it to the
      # model spends a whole turn on nothing and comes back as an API error.
      if ($text == null) or ($text | str trim | is-empty) {
        # a message this loop DECIDED about must never leave the log empty. "it answered
        # something and I cannot see what" is the state that made a whole class of failure
        # unreachable, and a chat window is not a place to debug from.
        if not $quiet {
          let from = (($m.from? | default "") | into string | str substring 0..12)
          let when = (($m.when? | default "unknown time") | into string)
          let kind = (if $text == null { "no text field" } else { "empty text" })
          print $"  in: ($from) > [not text — ($kind), ($when)]"
        }
        if $m.context_token != null {
          ilink send "这条我只认得文字——图片/语音/文件我还没实现。" --to $m.from --token $m.context_token --bot-id $bot_id | ignore
        }
        continue
      }
      if not ($m.from in $allowed) {
        if not $quiet { print $"  refused    ($m.from)" }
        if $m.context_token != null {
          ilink send "这个机器人只服务于它的绑定账号。把这条消息告诉你自己是没用的——需要在 bridge 的 --allow 里显式加上你。" --to $m.from --token $m.context_token --bot-id $bot_id | ignore
        }
        continue
      }

      # ── the reply channel ──
      # these three names ARE the conversation, published for the length of one turn: a tool
      # runs in a subprocess (`invoke-tool` spawns `^nu`) and can only see the environment.
      # the counter is a FILE for the same reason — the child cannot write back to this
      # process's memory, so "did the model actually say anything" has to land somewhere
      # this process can read afterwards.
      let reply_count = ($nu.temp-dir | path join $"nu-agent-reply-($acct.bot_id).count")
      rm -f $reply_count
      # the transcript of what was actually sent. a second file, not a second purpose for the
      # count: the count answers "did the model say anything", this answers "what did it say",
      # and the two are read at different moments.
      let reply_log = ($nu.temp-dir | path join $"nu-agent-reply-($acct.bot_id).jsonl")
      rm -f $reply_log
      $env.NU_AGENT_WECHAT_TO = $m.from
      $env.NU_AGENT_WECHAT_TOKEN = $m.context_token
      $env.NU_AGENT_WECHAT_BOT_ID = $acct.bot_id
      $env.NU_AGENT_WECHAT_COUNT = $reply_count
      $env.NU_AGENT_WECHAT_LOG = $reply_log

      # a slash command is answered directly and never reaches the model. it is also the only
      # thing here that runs from the same allowlist WITHOUT spending a model call.
      let reply = (
        if ($text | str trim | str starts-with "/") {
          try { slash $text } catch {|e| $"命令出错: ((reason $e) | str substring 0..300)" }
        } else {
          # re-read the set every message: /load and /unload take effect on the next one
          let active = (if ($tools | is-empty) { toolset show | get modules } else { $tools })
          if not $quiet { print $"  in: ($m.from | str substring 0..12) > ($text | str substring 0..60) [($active | length) modules]" }
          answer $text $active
        }
      )

      # the model has usually sent for itself by now, through `reply`. this only fires when it
      # sent nothing at all — a slash command (no model, no tool set), or a run that ignored
      # the brief. a fallback, not the normal path, which is why clipping is acceptable here.
      let said = (if ($reply_count | path exists) { open $reply_count | into int } else { 0 })
      # one JSON object per reply, written by the tool as it sent. read here, not in the tool,
      # because this process owns the log — the tool only knows its own file.
      # the field is `bytes` (see the note in reply.nu — `str length` counts bytes, not chars).
      # the fallback record keeps the same shape so the print loop below needs no second case.
      let transcript = (
        if ($reply_log | path exists) {
          open $reply_log | lines | compact | each {|l|
            try { $l | from json } catch { {n: 0, bytes: 0, text: $l} }
          }
        } else { [] }
      )
      let fallback = (
        if $said > 0 { null } else {
          let body = (clip $reply)
          let n = ($body | str length)
          let r = (try { ilink send $body --to $m.from --token $m.context_token --bot-id $bot_id } catch {|e| {ok: false, error: (reason $e)}})
          {
            bytes: $n
            ok: ($r | get --optional ok | default false)
            error: ($r | get --optional error | default '?')
          }
        }
      )

      if not $quiet {
        # no `\(` escape and no arrow glyphs here: the interpolated-paren form was a parse
        # error whose message pointed at a column that did not explain itself
        if $fallback == null {
          print $"  reply tool sent ($said) message\(s)"
          # the bodies themselves. without them the log says how MANY were sent and nothing
          # about WHAT — which is the state that made the 22:20 message unanswerable: a reply
          # reading "agent 出错: …" appeared in the chat while the log showed no error at all,
          # and there was no way to tell a relayed string from a real failure.
          for r in $transcript {
            print $"  ── reply ($r.n)/($said) · ($r.bytes) bytes ──"
            print $r.text
          }
        } else if $fallback.ok {
          print $"  reply tool unused — sent the final text, clipped to ($fallback.bytes) bytes"
        } else {
          print $"  send failed: ($fallback.error)"
        }
      }
      $handled = $handled + 1
      if $once { return {ok: true, handled: $handled} }
    }
    if $once { return {ok: true, handled: 0} }
  }
}
