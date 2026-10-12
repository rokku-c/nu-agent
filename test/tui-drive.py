#!/usr/bin/env python3
"""Drive `agent tui` through a pty, so the interactive path can be tested.

Why a pty, and why python: the TUI reads its input with `input --reedline`, which
needs a real terminal — this is what a person actually types into. nushell cannot
allocate one for itself, and no nushell-only harness can send keystrokes to it.

This is a test helper, not part of the agent. It is invoked by test/tui.nu.

usage: tui-drive.py <repo> <session-dir> <session> <tools-from> <prompt>...
prints the whole session, ANSI stripped, on stdout.
"""

import os, pty, re, select, shutil, sys, time

repo, session_dir, session, tools = sys.argv[1:5]
prompts = sys.argv[5:]
# execve needs a full path: a bare "nu" is looked up by the shell, not by exec
nu = os.environ.get("NU_BIN") or shutil.which("nu")
if not nu:
    sys.exit("tui-drive: no nu on PATH (set NU_BIN)")

script = os.path.join(session_dir, "_tui_script.nu")
os.makedirs(session_dir, exist_ok=True)
with open(script, "w") as f:
    f.write(f"agent tui --session {session} --tools-from [{tools}]\n")

env = dict(os.environ)
env.update({"NU_AGENT_ROOT": repo, "NU_SESSION_DIR": session_dir, "TERM": "xterm-256color"})

pid, fd = pty.fork()
if pid == 0:
    os.execve(nu, [nu, "--config", f"{repo}/test/config.nu", "--env-config", "/dev/null", script], env)

out = b""

def pump(seconds):
    global out
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.25)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return
        if not chunk:
            return
        out += chunk

pump(3.0)
for p in prompts:
    try:
        os.write(fd, p.encode() + b"\r")
    except OSError:
        break
    # a turn that has to call a tool needs a second round trip
    pump(45.0)
try:
    os.write(fd, b"/quit\r")
except OSError:
    pass
pump(2.0)

# strip ANSI, and the per-keystroke echo reedline leaves behind when input is fed
# in one byte at a time rather than typed
text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[78]", "", out.decode(errors="replace"))
print(text)
