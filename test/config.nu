# test/config.nu — isolated config for exercising the modules
#
# never used by an installed setup; its whole point is that it loads the modules
# from this checkout and touches nothing the user owns.
#
# the `use` lines are RELATIVE on purpose: a relative path in `use` resolves
# against the containing file's directory (measured), not the cwd — so this file
# works from any checkout location with no generation step. `$env.X | path join`
# would NOT work here: an env var is not a parse-time constant, and `use` is
# resolved at parse time.

# runtime path lookups (trace template, host sync) read this. it CANNOT be
# inferred here: an env var is not a parse-time constant (so it can't feed the
# `use` lines above), and a file cannot learn its own directory at eval time
# ($env.FILE_PWD is empty at runtime — measured). so it is passed in, exactly as
# an installed config.nu carries it.
if ($env.NU_AGENT_ROOT? | is-empty) {
    print -e "test config: NU_AGENT_ROOT is unset — `trace write` and `host sync` will fail; set it to this checkout's path"
}

# credentials: read from Claude Code's settings.json at runtime, exactly like an
# installed config does — so no secret is ever written into this repo.
# only fill in what is not already set, so a caller (CI, or a test) can inject
# credentials instead of having them overwritten from settings.json.
if ($env.ANTHROPIC_AUTH_TOKEN? | is-empty) {
    try {
        let cc = (open ~/.claude/settings.json | get env)
        $env.ANTHROPIC_AUTH_TOKEN = $cc.ANTHROPIC_AUTH_TOKEN
        $env.ANTHROPIC_BASE_URL = $cc.ANTHROPIC_BASE_URL
        $env.ANTHROPIC_MODEL = $cc.ANTHROPIC_MODEL
    } catch {
        print -e "test config: no ANTHROPIC_* credentials found — network tests will be skipped"
    }
}

# ── capabilities: these are what the MCP allowlist exposes ──
use ../tools/shell.nu
use ../tools/calc.nu
use ../tools/proc.nu
use ../tools/host.nu
use ../tools/image.nu
use ../tools/jsonschema.nu
use ../tools/nu-shell.nu
use ../tools/peers.nu
use ../tools/read.nu
use ../tools/remote.nu
use ../tools/toon.nu
use ../tools/edit.nu
use ../tools/write.nu

# ── apps: composed capability sets, not installed by install.nu ──
use ../apps/financial/series.nu
use ../apps/financial/macro.nu
use ../apps/financial/market.nu
use ../apps/financial/pred.nu
use ../apps/financial/backtest.nu
use ../apps/financial/trig.nu
use ../apps/financial/daily.nu
use ../apps/financial/factor.nu
use ../apps/financial/filings.nu
use ../apps/financial/options.nu
use ../apps/wechat/ilink.nu
use ../apps/wechat/bridge.nu
use ../apps/wechat/reply.nu
use ../apps/toolset.nu

# ── runtime: loaded, but only what the allowlist names becomes a tool ──
use ../core/agent.nu
use ../core/context.nu
use ../core/expose.nu
use ../core/markdown.nu
use ../core/mcp.nu
# policy is runtime machinery (agent.nu imports it privately), but the tests
# exercise its rule matching directly rather than only through a live run
use ../core/policy.nu
use ../core/reason.nu
use ../core/handoff.nu
use ../core/interactive.nu
use ../core/session.nu
use ../core/shells.nu
use ../core/task.nu
use ../core/style.nu
use ../core/trace.nu
