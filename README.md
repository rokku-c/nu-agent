# nu-agent

An agent runtime that runs inside [nushell](https://www.nushell.sh).

You write nushell. The model gets capabilities.

```nushell
agent chat "what is in this screenshot?" --image shot.png

let tools = (expose from-module calc)
agent "what is (1234 * 5678) + 99? use the calc tool" --tools $tools
```

The same modules are also an **MCP server**, so any MCP client — Claude Code,
an IDE, another agent — can use this machine's shell, files, and remote hosts as
tools. Nushell is the host; the agent never has to know.

---

## The one rule

> **The agent sees capabilities, not the host. The only thing that says `nu` is
> the tool that hands it nushell.**

That is why the tools are named `read`, `write`, `bash`, `calc`, `host` — and
why exactly one is named `nu-shell`. A model that is writing nushell code needs
to know the language it is writing; it does not need to know that `read` was
implemented in nushell. Every other `nu-` prefix was leaking the host into the
agent's view of the world.

This repo is the reorganisation of a working set of modules that had grown up
inside one person's nushell config directory, named `nu-read`, `nu-bash`,
`nu-calc`, … The behaviour is the same. The names are not.

---

## Install

```nushell
git clone git@github.com:rokku-c/nu-agent.git
cd nu-agent

nu install.nu --check      # pre-flight: shows what it would write, verifies it resolves
nu install.nu              # writes it
```

Then reopen nushell. `install.nu` appends **one marker-guarded block** to your
`config.nu` and nothing else; `--uninstall` removes exactly that block again.

### MCP

`install.nu` prints the entry to paste into your MCP client:

```json
{"mcpServers":{"agent":{"type":"stdio","command":"nu",
  "args":["--config","/path/to/config.nu","/path/to/nu-agent/core/mcp-server.nu"],
  "env":{"NU_MCP_MODULES":"*"}}}}
```

Tools then appear as `mcp__agent__read`, `mcp__agent__bash`,
`mcp__agent__nu-shell`, and so on.

---

## Using it

```nushell
# one turn
agent chat "explain the borrow checker in one sentence"
agent chat "summarise this" --system "be terse" --max-tokens 4096
agent chat "hi" --json | get usage
agent config                                    # what is in effect, never the token

# the loop: model wants tools → they run → results go back → until it stops
let tools = (expose from-module calc)
agent "what is (1234 * 5678) + 99? use the calc tool" --tools $tools

# streaming, rendering, thinking
agent chat "write a quicksort" --stream --md
agent "…" --tools $tools --verbose --show-thinking

# give it eyes, and a working directory's worth of tools
agent chat "what is in this diagram?" --image diagram.png
agent "add a --verbose flag to src/main.rs" --tools (expose from-module [read write bash])

# attach an external MCP server
agent "open an issue titled 'hi'" --mcp [["npx" "-y" "@modelcontextprotocol/server-github"]]

# a browsable trace of the run
agent "…" --tools $tools --json | trace write run.html

# sessions: opt-in, and ephemeral unless you ask
agent "start something" --session my-run --tools-from [read write bash]
agent "carry on" --resume --session my-run
session list
```

### The tools

| tool | what it does |
|---|---|
| `read` / `write_file` / `write_range` / `write_replace` | files, local or `--host` |
| `bash` | run a shell command, local or `--host` |
| `nu-shell` | **run nushell code** — every module below is callable inside it |
| `calc` | arithmetic, sandboxed to `+ - * / % ^ ( )` |
| `host_*` | register hosts/containers; `exec` / `fetch` / `put` / `sync` over ssh or docker |
| `remote` | run nushell pipelines on a registered host |
| `peers_*` | enumerate the AI agent processes running on this machine |
| `image_show` / `image_info` | inline images (kitty graphics) and their dimensions |
| `jsonschema_infer` / `jsonschema_from-samples` | real data → JSON Schema, to constrain structured output |
| `toon_encode` | [TOON](https://github.com/toon-format/toon) — 30-60% fewer tokens than JSON for uniform arrays |

`expose from-module <name>` turns any module's command signatures into tool
definitions, so pointing the model at a tool you wrote yourself is one line.

---

## Layout

```
core/     the runtime — not offered to the model
  agent.nu        the loop: request, stream, tool execution, folding, MCP, skills
  expose.nu       command signatures → tool definitions
  context.nu      context capture and folding
  policy.nu       the tool permission gate (opt-in; default allow)
  session.nu      persist a run and resume it later (opt-in; default ephemeral)
  task.nu         (planned) subagent orchestration
  markdown.nu     markdown rendered for a terminal
  style.nu        ANSI colour, off automatically when piped
  mcp.nu          MCP client
  mcp-server.nu   MCP server
  provider.nu     dialect dispatch + execution
  provider/       anthropic · stream (the SSE machine) · transport
  trace.nu        a run → a browsable HTML page
  layout.nu       where the checkout is, at runtime
  quote.nu        POSIX quoting

tools/    the capabilities — these become the model's tools
test/     unit · resolve · stream · policy · session · mcp · e2e
```

**A file's name is its public tool name.** `tools/read.nu` exports `main`, so
the module is `read` and the tool is `read`. That makes the filename API
surface, not a file label — which is why stems must stay globally unique (two
modules with the same stem *merge*, silently, rather than shadowing).

---

## Measured constraints

These were found by experiment and they shaped the design. They are recorded
here because each one has a failure mode that looks like something else.

**`NU_LIB_DIRS` is stripped from child processes.** It is visible in-process
(`[/tmp/w, …/scripts, …/completions]`) and gone in a `^nu` child. Every tool call
*is* a child process (`invoke-tool` spawns `^nu --config $nu.config-path`), so
anything resolved through lib dirs works at the prompt and fails on every single
tool call — with an empty tool list, which is a legal answer and therefore
silent.

**An env var is not a parse-time constant**, so `$env.NU_AGENT_ROOT | path join
…` cannot appear in a `use` line at all. Neither can `$env.FILE_PWD` (empty at
runtime inside a command; a parse error inside `use`). A file also cannot set an
env var *and* use it in its own `use` lines — parsing happens first.

So: **`config.nu` carries absolute paths** (the installer writes them), and
**modules import each other relatively** — a relative `use` resolves against the
containing file's directory, not the cwd. Both hold at any process depth
(verified parent → child → grandchild), with no environment variable involved.

**`error make`'s `help` and `labels` are unreachable from `catch`** — only `msg`
and `rendered` survive, and the tool executor reads only `msg`. Any message meant
for the model has to fit in `msg`.

**Module names `http` and `reduce` are taken** by builtins; `schema` is too.
`read`, `write`, `calc`, `bash`, `host`, `remote`, `image`, `peers`, `toon`,
`style`, `trace`, `context`, `agent`, `policy`, `task` are all free.

**Stdout is data.** In the MCP server one stray character breaks every client;
`--stream` prints model text there; and the test harness had to stop reporting
its results on stdout because the `--stream` case polluted it.

---

## Testing

```nushell
nu test/run.nu              # everything
nu test/run.nu unit mcp     # or just some suites
```

| suite | covers |
|---|---|
| `unit` | pure functions — schema generation, folding, markdown, TOON, calc, colour |
| `resolve` | module resolution **in a child process**, stem uniqueness, the naming contract |
| `stream` | the SSE state machine, replayed from canned bytes — thinking, tool fragments, no-SSE errors |
| `policy` | the permission gate: matching, refusal wording, deferral, and enforcement through the tool executor |
| `session` | persistence and resume, including the invariant that a folded run stores its unfolded history |
| `mcp` | the real server over real stdio, including stdout purity |
| `e2e` | a real model endpoint — tool round-trip, streaming, images, traces |

`e2e` needs `ANTHROPIC_AUTH_TOKEN` (or a Claude Code `settings.json`). Without
it the suite reports itself **skipped** — visible, exit code still zero. A
genuine failure exits non-zero, so it drops into CI unchanged.

`resolve` exists because that failure mode is silent. An empty tool list looks
exactly like a server with nothing to offer.

---

## Committing and pushing

```bash
git config user.name  "rokku-c"
git config user.email "88531007+rokku-c@users.noreply.github.com"
git add -A
git commit -m "…"
git push -u origin HEAD
```

Attribution lines belong at the end of a commit message:

```
Co-Authored-By: Claude Code <noreply@anthropic.com>
```

The remote is `git@github.com:rokku-c/nu-agent.git`, over SSH.

---

## Roadmap

The runtime is whole; what is missing is the machinery around it. In order:

1. **provider** — stop hardcoding Anthropic. Anthropic's content-block shape
   stays the internal canonical form (the loop, context, trace and MCP already
   speak it), so `anthropic.nu` is a pass-through and all the translation lives
   in `openai.nu`.
2. ~~**policy**~~ — done, see `core/policy.nu`.
3. ~~**session**~~ — done, see `core/session.nu`. The invariant held: the loop
   carries an append-only `canonical` list that folding never touches, and that
   is what gets stored — a run whose context was folded still resumes with its
   real history.
4. **task** — subagents. Falls out of the design almost free, because a tool
   already runs out-of-process: a subagent is a nested loop in that child.

## License

MIT
