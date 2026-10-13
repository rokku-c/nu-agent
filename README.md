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

That is why the tools are named `read`, `write`, `edit`, `shell` — and
why exactly one is named `nu-shell`. A model that is writing nushell code needs
to know the language it is writing; it does not need to know that `read` was
implemented in nushell. Every other `nu-` prefix was leaking the host into the
agent's view of the world.

This repo is the reorganisation of a working set of modules that had grown up
inside one person's nushell config directory, named `nu-read`, `nu-bash`,
`nu-calc`, … The behaviour is the same. The names are not.

---

## Install

### One command

```bash
git clone git@github.com:rokku-c/nu-agent.git ~/nu-agent && nu ~/nu-agent/install.nu
```

Then reopen nushell. That is the whole install.

### One command, including the MCP server

```bash
git clone git@github.com:rokku-c/nu-agent.git ~/nu-agent && nu ~/nu-agent/install.nu --mcp
```

`--mcp` also registers the server in your MCP client config (default
`~/.claude.json`). It backs the file up first, leaves every other server and
every unrelated key alone, and does nothing on a second run. Restart the client
to pick it up.

### Pre-flight

```bash
nu ~/nu-agent/install.nu --check
```

Shows the exact block it would write, the MCP entry, and — the useful part —
runs it against a **child process**, because that is where a broken install
fails silently. It writes nothing.

### Uninstall

```bash
nu ~/nu-agent/install.nu --uninstall --uninstall-mcp
```

`--uninstall` removes exactly the block it wrote and nothing else; it leaves the
backup and your other MCP servers alone. Drop `--uninstall-mcp` to keep the MCP
entry.

If the clone is already gone, the block is delimited and can be removed by hand:
delete everything between the `nu-agent (begin)` and `nu-agent (end)` markers in
`config.nu`.

### What it writes

`install.nu` appends **one marker-guarded block** to your `config.nu` — a
`NU_AGENT_ROOT` line and one `use` line per module, all absolute paths. Nothing
else is touched, no environment variable is needed, and re-running replaces the
block in place instead of stacking another one.

### MCP

Tools appear as `mcp__agent__read`, `mcp__agent__shell`,
`mcp__agent__nu-shell`, and so on. If you would rather wire it up by hand:

```json
{"mcpServers":{"agent":{"type":"stdio","command":"nu",
  "args":["--config","/path/to/config.nu","/path/to/nu-agent/core/mcp-server.nu"],
  "env":{"NU_MCP_MODULES":"*"}}}}
```

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
agent "add a --verbose flag to src/main.rs" --tools (expose from-module [read edit])

# attach an external MCP server
agent "open an issue titled 'hi'" --mcp [["npx" "-y" "@modelcontextprotocol/server-github"]]

# a browsable trace of the run
agent "…" --tools $tools --json | trace write run.html

# delegation: the model gets a `task` tool that starts a nested run
agent "audit every file under src/ for unwrap() and summarise" --tools-from [read edit shell task]

# sessions: opt-in, and ephemeral unless you ask
agent "start something" --session my-run --tools-from [read write edit shell]
agent "carry on" --resume --session my-run
session list

# a conversation, not a run: each turn is added to the same session
agent chat "my project is called Halcyon" --session conv
agent chat "what is my project called?" --resume --session conv

# interactive
agent tui                          # new conversation
agent tui --resume                 # the newest one
agent tui --session my-run --tools-from [read shell nu-shell]

# continue something another agent was doing
handoff list --from claude-code
handoff import claude-code 835031fb --into picked-up
agent tui --resume --session picked-up
```

### The tools

| tool | what it does |
|---|---|
| `read` / `write` / `edit` | files, local or `--host`. `write` is a whole file; `edit` replaces text (`--old`/`--new`) or a line range (`--from`/`--to`/`--content`) |
| `shell` | run a shell command, local or `--host`. `--list` shows the shells this machine has; `--shell fish` runs one call through another; `$env.NU_AGENT_SHELL` changes the default |
| `exec` | run a program with argv, **no shell in between** — nothing re-splits an argument, so a filename with a space or a `$(…)` is just a filename. Local only: a remote argv would have to travel through the far end's shell, which is the thing this avoids. (The module is `core/../tools/proc.nu`, because `exec` and `run` are nushell parser keywords and cannot be command names; the tool name is the one nu does not own.) |
| `nu-shell` | **run nushell code** — every module below is callable inside it |
| `calc` | arithmetic, sandboxed to `+ - * / % ^ ( )` — not in the default set; a model is worse at arithmetic than at calling a tool, but not so much worse that it earns a slot ahead of `edit` |
| `host_*` | register hosts/containers; `exec` / `fetch` / `put` / `sync` over ssh or docker |
| `remote` | run nushell pipelines on a registered host |
| `peers_*` | enumerate the AI agent processes running on this machine |
| `image_show` / `image_info` | inline images (kitty graphics) and their dimensions |
| `jsonschema_infer` / `jsonschema_from-samples` | real data → JSON Schema, to constrain structured output |
| `toon_encode` | [TOON](https://github.com/toon-format/toon) — 30-60% fewer tokens than JSON for uniform arrays |

`expose from-module <name>` turns any module's command signatures into tool
definitions, so pointing the model at a tool you wrote yourself is one line.

---

## Interactive

```nushell
agent tui
agent tui --resume --session my-run
```

`›` prompts; a line is one streamed turn against the session. The default tool
set is `read`, `write`, `edit`, `shell` — the four a coding agent reaches for.
`/shell fish` switches which shell `shell` runs through for the rest of the
session. `/help` lists the
commands — `/session`, `/new`, `/resume`, `/tools`, `/model`, `/system`,
`/history`, `/clear`, `/quit`.

It is a **line-based** interactive session, not a full-screen one. The input line
is nushell's `input --reedline`, so arrow keys, word motions, Ctrl-R history
search and bracketed paste all work — reedline implements them. A full-screen TUI
is possible in nushell (`input --numchar 1` reads single keystrokes), but then
editing, paste and unicode width become mine to get right, and getting them wrong
is worse than not having a frame.

Two things worth knowing, both measured: `input --reedline` must not sit inside a
`try` — it returns `""` instantly and forever instead of waiting for a line, so
the read and the loop around it are bare. And each turn is written to the session
as it completes, so quitting, crashing or closing the terminal loses at most the
turn in flight.

## Handoff

```nushell
handoff sources                        # which agents have sessions here, and how many
handoff list                           # recent sessions across all of them
handoff list --from codex --cwd .
handoff read claude-code 835031fb      # what would be imported, without importing
handoff import claude-code 835031fb --into picked-up --tail 20
agent "carry on from where that left off" --resume --session picked-up
```

Reads **claude-code**, **codex** and **pi** transcripts. It imports the
conversation — the user and assistant turns, in order — and not the tool calls.

That is a deliberate limit, not an omission. The three agents represent tools
three different ways and the calls they made are not nu commands: a codex
`function_call` for its shell tool has no nu equivalent, and replaying one
through the agent loop would tell the model it had run something it had not. So
tool calls are counted and reported instead, and the resumed run is told both
where it came from and that tools named in the older transcript may not exist
here or may behave differently.

**Only a tail is loaded by default.** These transcripts get large — the one this
was written against holds 700+ messages across 4000 tool calls — so a handoff
records how much to load and the rest stays in the store, readable with
`session show`. The full history is what gets written back, so resuming never
truncates it.

## Layout

```
core/     the runtime — not offered to the model
  agent.nu        the loop: request, stream, tool execution, folding, MCP, skills
  expose.nu       command signatures → tool definitions
  context.nu      context capture and folding
  handoff.nu      read another agent's transcript (claude-code · codex · pi)
  interactive.nu  the `agent tui` loop
  policy.nu       the tool permission gate (opt-in; default allow)
  session.nu      persist a run and resume it later (opt-in; default ephemeral)
  task.nu         delegate a subtask to a nested run (the `task` tool)
  markdown.nu     markdown rendered for a terminal
  style.nu        ANSI colour, off automatically when piped
  mcp.nu          MCP client
  mcp-server.nu   MCP server
  provider.nu     dialect dispatch + execution
  provider/       anthropic · openai · stream (the SSE machine) · transport
  trace.nu        a run → a browsable HTML page
  layout.nu       where the checkout is, at runtime
  quote.nu        POSIX quoting

tools/    the capabilities — these become the model's tools
test/     unit · resolve · stream · policy · handoff · session · task · mcp · e2e
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
`read`, `write`, `edit`, `shell`, `exec`, `calc`, `host`, `remote`, `image`, `peers`, `toon`,
`style`, `trace`, `context`, `agent`, `policy`, `task` are all free.

**`flatten` recurses into records, and whether it does depends on the input.**
Measured: `[tool] | flatten` hoists a nested `input_schema` and destroys it,
while `[[tool] [tool]] | flatten` leaves it alone — so the same expression is
safe with two elements and silently wrong with one. In the OpenAI dialect that
turned a single `tool_calls` entry from an array into a bare object, which every
endpoint rejects, and it only happened when the model made exactly one tool call.
Use an explicit one-level concat instead.

**A newline before `else` parses as a command named `else`.** `if … { }` then
`else` on the next line is fine at the top level of a `( )` grouping and fails
inside a closure. The failure surfaces as "Eval block failed with pipeline
input" wrapping "External command failed", pointing at the call site rather than
the line — so it reads like the caller is broken.

**A literal list of differently-shaped records does not type.** `[{type:
"tool_result", …} {type: "text", …}]` fails where the literal is written, with
the same unhelpful wrapper. The runtime never builds one (it appends, or parses
JSON), but a test that writes one by hand will fail for reasons that have nothing
to do with the code under test.

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
| `openai` | the OpenAI dialect's translation, plus the streaming state it needs |
| `stream` | the SSE state machine, replayed from canned bytes — thinking, tool fragments, no-SSE errors |
| `policy` | the permission gate: matching, refusal wording, deferral, and enforcement through the tool executor |
| `session` | persistence and resume, the resume window, and the invariant that a folded run stores its unfolded history |
| `handoff` | the three transcript formats, the import stamp, and the tail|
| `task` | subagents: depth and capability guards, lineage, and the stored child transcript |
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

1. ~~**provider**~~ — done, see `core/provider/`. Anthropic stayed the internal
   canonical shape, so `anthropic.nu` is a pass-through and `openai.nu` carries
   the translation — including the one piece of stream state the two wires
   differ on.
2. ~~**policy**~~ — done, see `core/policy.nu`.
3. ~~**session**~~ — done, see `core/session.nu`. The invariant held: the loop
   carries an append-only `canonical` list that folding never touches, and that
   is what gets stored — a run whose context was folded still resumes with its
   real history.
4. ~~**task**~~ — done, see `core/task.nu`. It did fall out nearly free: a tool
   already runs out-of-process, so a subagent is a nested loop in that child. The
   work was in the guard rails — a child may narrow its parent's capabilities and
   policy but never widen them, and it is handed the parent's *compiled* rules
   rather than a path, so it cannot escape by pointing `NU_POLICY_FILE` somewhere
   empty.

## Providers

```nushell
agent chat "hi" --provider openai        # or anthropic, the default
$env.NU_AGENT_PROVIDER = "openai"        # or set it for the session
```

| | Anthropic | OpenAI-compatible |
|---|---|---|
| base URL | `ANTHROPIC_BASE_URL` | `OPENAI_BASE_URL` (includes `/v1`, as every SDK treats it) |
| token | `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` | `OPENAI_API_KEY` |
| model | `ANTHROPIC_MODEL` | `OPENAI_MODEL` |

With no explicit choice, the dialect is inferred — but only when exactly one of
the two has credentials, rather than guessed from a model name.

Both are exercised end-to-end in the `e2e` suite.

## License

MIT
