# reply.nu — the bridge's send channel, handed to the model as a tool
#
#   use reply.nu
#
#   reply "第一段"          # → 一条微信消息
#   reply "第二段"          # → 又一条
#
# ── why this is a tool and not the bridge's job ──
# WeChat caps one message, and the bridge used to answer by passing the model's final text
# through `clip`, which cuts at a character count — mid-sentence, mid-table, mid-list. a
# character count does not know where a break belongs; the model does. so the model sends,
# and the bridge keeps `clip` only for the run that sent nothing at all.
#
# ── the boundary, said plainly ──
# this works INSIDE `bridge serve` and nowhere else. the conversation — who to reply to, and
# the context_token the server needs to locate it — is per-message state the bridge
# publishes into the environment for the length of one turn. from a terminal there is no
# conversation, so `reply` refuses rather than inventing one.
#
# the credentials ride in the ENVIRONMENT because a tool runs in a subprocess
# (`invoke-tool` spawns `^nu --config $nu.config-path`) and cannot see the caller's
# variables — the same reason NU_AGENT_SESSION and NU_AGENT_TOOLS are passed this way.
# the count below is a FILE for the same reason: a child cannot write back to its parent's
# memory, so "did the model say anything" has to land where the parent can read it.

use ./ilink.nu

# WeChat's ceiling on one message. the bridge used this number for its truncation cap; it
# lives here now because this is the only place left that cares. it is REPORTED, not
# enforced — the server is the authority, and when it rejects a message the model gets that
# error back as an ordinary tool_result and can split the text itself.
const CEILING = 1800

def env-or-empty [name: string]: nothing -> string {
  $env | get --optional $name | default ""
}

# count this reply, so the bridge can tell whether the model said anything at all
def bump []: nothing -> int {
  let p = (env-or-empty "NU_AGENT_WECHAT_COUNT")
  if ($p | is-empty) { return 0 }
  let n = ((if ($p | path exists) { open $p | into int } else { 0 }) + 1)
  $n | save -f --force $p
  $n
}

# record what was actually sent, so the bridge can print it into its own log at the end of the
# turn. same mechanism as the count file, and for the same reason: a child cannot write back to
# its parent's memory, so the transcript has to land on disk where the parent can read it.
#
# this exists because its absence cost a real answer. on 2026-10-13 a turn sent 8 messages and
# the log recorded only "reply tool sent 8 messages" — so when a message reading
# "agent 出错: Eval block failed with pipeline input" turned up in the chat, there was no way to
# tell whether the bridge's error path had fired (it had not: no error line) or the model had
# quoted the error string out of the source it was reading (it was reading exactly that file).
# one line of recorded text would have settled it.
def record-sent [n: int, text: string]: nothing -> nothing {
  let p = (env-or-empty "NU_AGENT_WECHAT_LOG")
  if ($p | is-empty) { return }
  # the trailing newline is load-bearing. `save --append` concatenates with NO separator —
  # measured: two records went in and came out joined on one line — so without it the reader
  # downstream sees one malformed object and falls back silently instead of failing loudly.
  #
  # it is `bytes`, not `chars`, because that is what `str length` returns in nushell 0.116 —
  # measured: "我先查一下数据" is 7 chars and `str length` says 21. the field was named `chars`
  # for about twenty minutes and the first turn it logged read "reply 1/6 · 21 chars" for a
  # seven-character message, which is the sort of number a reader trusts and draws conclusions
  # from. `str stats | get chars` is the character count; this is the byte count, and says so.
  ((({n: $n, bytes: ($text | str length), text: $text} | to json -r) + (char nl)) | save -f --append $p)
}

# send one message to the person who wrote to the bot.
export def main [
  text: string   # 要发出去的内容。一条微信消息——长回答请分成多次 reply 调用
]: nothing -> record {
  let to = (env-or-empty "NU_AGENT_WECHAT_TO")
  let token = (env-or-empty "NU_AGENT_WECHAT_TOKEN")
  let bot_id = (env-or-empty "NU_AGENT_WECHAT_BOT_ID")

  if ($to | is-empty) or ($token | is-empty) {
    error make { msg: "这次运行没有绑定微信会话——reply 只在 bridge serve 里能用。在终端里回答就把文字打出来" }
  }

  let r = (ilink send $text --to $to --token $token --bot-id $bot_id)
  # counted only AFTER a send that did not raise. a failed reply leaving the count at zero is
  # deliberate: it is what lets the bridge's fallback fire, so a `reply` that the server
  # rejected does not end as silence.
  let n = (bump)
  let chars = ($text | str length)
  record-sent $n $text

  {
    sent: true
    message: $n
    chars: $chars
    message_id: ($r | get --optional message_id)
    # a hint, not a refusal: the number is the bridge's own guess at the ceiling, and the
    # only authority is the server. if it rejects the message, that error comes back here
    # and the useful move is to split the text and call reply again.
    over_ceiling: ($chars > $CEILING)
  }
}
