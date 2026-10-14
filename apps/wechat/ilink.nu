# ilink.nu — sign in to WeChat's official bot channel
#
#   use ilink.nu
#
#   ilink qr                     # ask for a QR code and print the URL to scan
#   ilink login                  # scan it, then poll until confirmed; stores the token
#   ilink accounts               # what is stored, and where
#
# ── what this is ──
# iLink (智联) is Tencent's OFFICIAL bot channel for personal WeChat accounts, opened in
# 2026. it is HTTP/JSON on Tencent's own servers, governed by 微信ClawBot功能使用条款 — not a
# reverse-engineered iPad protocol, which is what it looks like at a glance and what an
# earlier guess of mine got wrong. the difference matters: this one is supported, and it will
# not get an account banned for using it.
#
# ── the shape of a login ──
#   1. get_bot_qrcode?bot_type=3        → {qrcode, qrcode_img_content}
#   2. the human scans it with WeChat
#   3. get_qrcode_status?qrcode=…       → long poll until a terminal status
#   4. confirmed → {bot_token, ilink_bot_id, baseurl, ilink_user_id}; persist the token
#
# ── three things the official client does that are easy to miss ──
#   · `X-WECHAT-UIN` is not random bytes: it is a random uint32 rendered as a DECIMAL STRING
#     and then base64'd. the decimal step is load-bearing and invisible.
#   · `scaned_but_redirect` exists: after a scan the server may move you to a different
#     base URL ("IDC redirect"), and continuing to poll the old one just hangs. the redirect
#     is honoured below.
#   · the long poll wants a CLIENT-side timeout around 35s — shorter and you abandon a reply
#     that was about to arrive; there is no server-side cap to lean on.
#
# ── what is stored, and how ──
# `bot_token` is a bearer token for a WeChat account. it lives in
# $NU_AGENT_WECHAT_DIR/<bot_id>.json, written 0600 (owner only), and is never printed — the
# helpers below redact it in output the way the official client does.

use ../../core/reason.nu

const BASE = "https://ilinkai.weixin.qq.com"
const BOT_TYPE = "3"
const POLL_TIMEOUT = 35sec

def store-dir []: nothing -> path {
  let override = ($env.NU_AGENT_WECHAT_DIR? | default "")
  if ($override | is-empty) { $nu.data-dir | path join "nu-agent-wechat" } else { $override | path expand }
}

def account-path [id: string]: nothing -> path { store-dir | path join $"($id).json" }

# a random uint32, rendered as a decimal string, then base64'd. that intermediate decimal
# step is what the official client does and what a naive `random chars | encode base64`
# would get wrong.
def uin []: nothing -> string {
  (random int 0..4294967295 | into string | encode base64)
}

# auth headers for every call that is not the QR handshake
def auth-headers [token: string]: nothing -> record {
  {
    "Authorization": $"Bearer ($token)"
    "AuthorizationType": "ilink_bot_token"
    "X-WECHAT-UIN": (uin)
    "User-Agent": "Mozilla/5.0"
  }
}

# the QR handshake needs no token, but does want the UIN header
def plain-headers []: nothing -> record {
  {"X-WECHAT-UIN": (uin), "User-Agent": "Mozilla/5.0"}
}

# a body that may arrive as JSON or as raw bytes, depending on the content type the server
# chose. nu parses the first and hands back bytes for the second — measured on this endpoint.
def as-json [x: any]: nothing -> any {
  if (($x | describe) | str starts-with "binary") { $x | decode | from json } else if (($x | describe) | str starts-with "string") { $x | from json } else { $x }
}

def redact [t: any]: nothing -> string {
  if $t == null { "(none)" } else if (($t | into string) | str length) < 12 { "(short)" } else { $"($t | into string | str substring 0..7)…" }
}

# ── commands ──

# ask the server for a QR code. returns the session `qrcode` (the handle to poll with) and
# the URL a human scans. the URL is what matters to a person; `qrcode` is what matters to us.
export def qr []: nothing -> record {
  let r = (as-json (http get -H (plain-headers) $"($BASE)/ilink/bot/get_bot_qrcode?bot_type=($BOT_TYPE)"))
  if ($r.qrcode? | default "") == "" {
    error make { msg: $"no qrcode in the response: ($r | to json -r | str substring 0..200)" }
  }
  {qrcode: $r.qrcode, url: $r.qrcode_img_content}
}

# poll a login session until it reaches a terminal state.
#
# the statuses, from the official client, are: wait · scaned · confirmed · expired ·
# scaned_but_redirect · need_verifycode · verify_code_blocked · binded_redirect. only
# `confirmed` yields a token; the redirect one means `baseurl` has changed and the poll must
# follow it, which is why the base is a variable below and not a constant.
export def login [
  --qrcode: string         # reuse a session from `ilink qr`; omit to start a fresh one
  --timeout: duration = 5min
]: nothing -> any {
  let sess = (if $qrcode == null { qr } else { {qrcode: $qrcode, url: null} })
  # always print the URL when we just fetched one — a login that never shows the code to scan
  # is the one thing this command cannot afford to get wrong
  if $sess.url != null { print $"scan this with WeChat:
  ($sess.url)" }

  mut base = $BASE
  let deadline = ((date now) + $timeout)
  mut last = ""

  loop {
    if (date now) > $deadline {
      return {ok: false, reason: "timeout", qrcode: $sess.qrcode, last_status: $last}
    }
    let resp = (
      try {
        as-json (http get --max-time $POLL_TIMEOUT -H (plain-headers) $"($base)/ilink/bot/get_qrcode_status?qrcode=($sess.qrcode)")
      } catch {|e| {status: "poll-error", error: ((reason $e) | str substring 0..120)}}
    )
    let st = ($resp.status? | default "unknown")
    if $st != $last { print $"  status: ($st)"; $last = $st }

    if $st == "confirmed" {
      mkdir (store-dir)
      let id = ($resp.ilink_bot_id | default "unknown")
      let acct = {
        bot_id: $id
        bot_token: $resp.bot_token
        baseurl: ($resp.baseurl? | default $BASE)
        user_id: ($resp.ilink_user_id? | default null)
        bound_at: (date now | format date "%Y-%m-%dT%H:%M:%S")
      }
      # written 0600 before anything else touches it: this file is a bearer token for a
      # personal WeChat account
      $acct | to json | save -f (account-path $id)
      chmod 600 (account-path $id)
      return {
        ok: true
        bot_id: $id
        token: (redact $acct.bot_token)
        baseurl: $acct.baseurl
        saved_to: ((account-path $id) | into string)
      }
    }
    if $st == "scaned_but_redirect" {
      let nb = ($resp.baseurl? | default null)
      if $nb != null { $base = $nb; print $"  → redirected to ($nb)" }
    }
    if $st == "expired" { return {ok: false, reason: "expired — run `ilink qr` again", qrcode: $sess.qrcode} }
    if $st == "verify_code_blocked" { return {ok: false, reason: "the server blocked verification for this account", qrcode: $sess.qrcode} }
    if $st == "poll-error" { print $"  ($resp.error | default 'poll failed')" }
  }
}

# what is stored here — never the token itself
export def accounts []: nothing -> any {
  let d = (store-dir)
  if not ($d | path exists) { return [] }
  glob ($d | path join "*.json") | each {|p|
    let a = (try { open $p } catch { null })
    if $a == null { null } else {
      {bot_id: $a.bot_id, user_id: ($a | get --optional user_id), baseurl: $a.baseurl,
       bound_at: $a.bound_at, token: (redact $a.bot_token)}
    }
  } | compact
}

# the stored account for a bot id, or the only one if there is exactly one
export def account [--bot-id: string]: nothing -> record {
  let all = (accounts)
  if ($all | is-empty) { error make { msg: "no account stored — run `ilink login`" } }
  let pick = (
    if $bot_id != null { $all | where bot_id == $bot_id | first }
    else if ($all | length) == 1 { $all | first }
    else { error make { msg: $"($all | length) accounts stored — name one with --bot-id" } }
  )
  if $pick == null { error make { msg: $"no stored account with bot_id ($bot_id)" } }
  open (account-path $pick.bot_id)
}

# ── receiving ──

const APP_ID = "bot"          # pkg.ilink_appid
const APP_CLIENT_VERSION = 132106   # buildClientVersion("2.4.10") = (2<<16)|(4<<8)|10
const CHANNEL_VERSION = "2.4.10"
const BOT_AGENT = "OpenClaw"        # what the official client sends by default

# the headers every non-QR call carries. `iLink-App-Id` and `iLink-App-ClientVersion`
# identify the CHANNEL BUILD to the server — the QR handshake did not need them, and these
# calls do. a nushell client reporting itself as openclaw-weixin 2.4.10 is a small
# misrepresentation, and it is the same trade the whole iLink path already makes: a supported
# product reached through an unsupported client.
def api-headers [token: string]: nothing -> record {
  {
    "Content-Type": "application/json"
    "Authorization": $"Bearer ($token)"
    "AuthorizationType": "ilink_bot_token"
    "X-WECHAT-UIN": (uin)
    "iLink-App-Id": $APP_ID
    "iLink-App-ClientVersion": ($APP_CLIENT_VERSION | into string)
    "User-Agent": "Mozilla/5.0"
  }
}

# the sync cursor. it is opaque, it is per-account, and it MUST be carried between runs —
# dropping it silently re-delivers or skips, and nothing in the response says which.
def buf-path [id: string]: nothing -> path { store-dir | path join $"($id).buf" }

def read-buf [id: string]: nothing -> string {
  let p = (buf-path $id)
  if ($p | path exists) { open --raw $p | str trim } else { "" }
}

# what a message says, flattened to what a caller can act on. text lives in
# item_list[].text_item; everything else (image/voice/file/video) is a CDN reference that
# would need the AES-128-ECB path to read, so it is reported as its kind, not as content.
export def "read-message" [m: record]: nothing -> record {
  let items = ($m.item_list? | default [])
  let texts = ($items | each {|i| $i.text_item?.text? } | compact)

  # a timestamp this code cannot read must come out null, not as a date it invented. measured:
  # the first real message decoded to 1970-01-01 00:00:01 — epoch plus one second — which is
  # what you get from a 1000 that is not milliseconds. rather than guess which field carries
  # the real time, every plausible name is tried and anything before the bot channel existed
  # is rejected as unreadable.
  let raw_ms = (
    [$m.create_time_ms? $m.create_time? $m.update_time_ms?]
    | compact | first
  )
  # nu's `into datetime` reads an INTEGER as NANOSECONDS. the field is milliseconds, so the
  # conversion is ms → ns (×1_000_000), and the obvious /1000 → seconds → into datetime is
  # wrong by a factor of a billion — it rendered every message as 1970-01-01 00:00:0x. the
  # guard below stays anyway: a time this code cannot read should be null, not a date it
  # invented.
  let when = (
    if $raw_ms == null or not (($raw_ms | describe) in ["int" "float" "string"]) { null } else {
      let ns = (($raw_ms | into int) * 1000000)
      let secs = (($raw_ms | into int) / 1000)
      if $secs < 1735689600 { null } else { ($ns | into datetime | format date "%Y-%m-%d %H:%M:%S") }
    }
  )

  {
    from: ($m.from_user_id? | default null)
    to: ($m.to_user_id? | default null)
    when: $when
    message_id: ($m.message_id? | default null)
    session_id: ($m.session_id? | default null)
    # an EMPTY group_id is not a group. the naive `!= null` said every private message was a
    # group message, which is the wrong way round for the one field that decides whether a
    # reply goes to a person or a room.
    is_group: (((($m.group_id? | default "") | into string) | str trim) | is-not-empty)
    text: (if ($texts | is-empty) { null } else { $texts | str join " " })
    kinds: ($items | each {|i| $i.type? } | compact)
    # the token an outbound reply MUST echo for this user; caching it is the whole reason a
    # bot cannot cold-start a conversation
    context_token: ($m.context_token? | default null)
  }
}

# long poll for new messages.
#
# a CLIENT-SIDE timeout is normal control flow here, not an error: the official client treats
# it as "nothing arrived", returns an empty batch and polls again. nu raises on its own
# timeout, so that exception is caught and turned back into the same empty result — otherwise
# an idle bot would look like a broken one.
export def updates [
  --bot-id: string             # which stored account
  --timeout: duration = 40sec  # per-poll; the official client uses 35s
  --once                       # one poll and return, instead of looping
  --dump: path                 # write the server's RAW messages here, untouched
  --raw                        # return the parsed messages
]: nothing -> any {
  let acct = (account --bot-id $bot_id)
  let id = $acct.bot_id
  mut buf = (read-buf $id)
  mut out = []

  loop {
    # a closure cannot capture a mutable variable, so the cursor is copied to an immutable
    # local before the try/catch that both branches need it in
    let cur = $buf
    let resp = (
      try {
        # --content-type is load-bearing: nu's `http post` sends form-encoded by default, and
        # the server answers a form-encoded getupdates with a well-formed EMPTY batch in 4ms
        # instead of long-polling. measured — the only symptom was that polling looked
        # instant and never delivered anything.
        as-json (http post --max-time $timeout --content-type application/json -H (api-headers $acct.bot_token) $"($acct.baseurl)/ilink/bot/getupdates"
          ({get_updates_buf: $cur, base_info: {channel_version: $CHANNEL_VERSION, bot_agent: $BOT_AGENT}} | to json))
      } catch {|e| {ret: 0, msgs: [], get_updates_buf: $cur, timed_out: true, note: ((reason $e) | str substring 0..80)}}
    )

    if ($resp.get_updates_buf? | default "") != "" and $resp.get_updates_buf != $buf {
      $buf = $resp.get_updates_buf
      $buf | save -f --force (buf-path $id)
    }

    let msgs = ($resp.msgs? | default [])
    if $dump != null and ($msgs | is-not-empty) {
      $msgs | to json | save -f --force $dump
      print $"  raw batch written to ($dump)"
    }
    if ($msgs | is-not-empty) {
      $out = ($out | append ($msgs | each {|m| read-message $m }))
    }

    if $once or ($msgs | is-not-empty) { break }
    if ($resp | get --optional ret | default 0) != 0 {
      return {ok: false, ret: $resp.ret, note: ($resp | to json -r | str substring 0..200), messages: $out}
    }
  }

  if $raw { return $out }
  {ok: true, count: ($out | length), cursor: ($buf | str length), messages: $out}
}

# ── sending ──

const MSG_TYPE_BOT = 2        # MessageType.BOT
const MSG_STATE_FINISH = 2    # MessageState.FINISH
const ITEM_TEXT = 1           # MessageItemType.TEXT

def client-id []: nothing -> string {
  # the official format is `<prefix>:<ms>-<8 hex>`; the shape is not cosmetic, the server
  # echoes it back on the reply
  $"openclaw-weixin:(((date now) | into int) / 1000000)-(random chars --length 8)"
}

# send a text message to a user, echoing the context_token of a message they sent.
#
# the token is not optional and cannot be invented: the server's `prepare` stage uses it to
# locate the conversation, and a missing one comes back as `{"ret":-2,"errmsg":"prepare
# failed"}`. that is the mechanism behind "a bot cannot cold-start" — someone has to speak
# first, and the reply is only valid against the token their message carried.
export def send [
  text: string
  --to: string                 # the user to reply to (a from_user_id you received)
  --token: string              # that user's context_token, verbatim
  --bot-id: string
]: nothing -> any {
  if $to == null { error make { msg: "--to is required" } }
  if $token == null { error make { msg: "--token is required: without a context_token from that user the server answers ret=-2 prepare failed, and there is no way to mint one" } }
  let acct = (account --bot-id $bot_id)
  let body = {
    msg: {
      from_user_id: ""
      to_user_id: $to
      client_id: (client-id)
      message_type: $MSG_TYPE_BOT
      message_state: $MSG_STATE_FINISH
      item_list: [{type: $ITEM_TEXT, text_item: {text: $text}}]
      context_token: $token
    }
    base_info: {channel_version: $CHANNEL_VERSION, bot_agent: $BOT_AGENT}
  }
  let r = (as-json (http post --max-time 20sec --content-type application/json -H (api-headers $acct.bot_token)
    $"($acct.baseurl)/ilink/bot/sendmessage" ($body | to json)))
  if (($r.ret? | default 0) != 0) {
    error make { msg: $"sendMessage ret=($r.ret) errmsg=($r.errmsg? | default '(none)')" }
  }
  {ok: true, message_id: ($r.message_id? | default null)}
}
