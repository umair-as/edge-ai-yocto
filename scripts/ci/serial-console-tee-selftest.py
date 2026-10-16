#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host self-test for scripts/dev/serial-console-tee.py on a pseudo-terminal pair:
board output reaches the log, `send --expect` returns the reply with escapes
stripped, Ctrl-C arrives as 0x03, a second serve on the same log and a port held
by another process are refused, `stop` exits cleanly, `send` without a serve is
refused. Exit 0 when every case passes.

  scripts/ci/serial-console-tee-selftest.py
"""
import atexit, os, pty, shutil, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.path.join(ROOT, "scripts", "dev", "serial-console-tee.py")
T = tempfile.mkdtemp(prefix="serial-tee-")
atexit.register(shutil.rmtree, T, True)
L = f"{T}/c.log"
m, sl = pty.openpty(); name = os.ttyname(sl)
got = []
def board():
    buf = b""
    while True:
        try: d = os.read(m, 1024)
        except OSError: return
        got.append(d); buf += d
        if b"ping\r" in buf:
            buf = b""; os.write(m, b"pong\r\n\x1b[1mlogin: \x1b[0m")
threading.Thread(target=board, daemon=True).start()
FAILS = []
def ok(c, msg):
    print(("PASS  " if c else "FAIL  ") + msg)
    if not c:
        FAILS.append(msg)
srv = subprocess.Popen([TOOL, "serve", "--port", name, "--log", L, "--allow-shared"])
time.sleep(1)
os.write(m, b"hello from board\n"); time.sleep(0.5)
ok(b"hello from board" in open(L, "rb").read(), "board output reaches the log")
r = subprocess.run([TOOL, "send", "--log", L, "--expect", "login: ", "ping"], capture_output=True, text=True)
ok(r.returncode == 0 and "pong" in r.stdout and "\x1b" not in r.stdout, f"send --expect returns the reply, escapes stripped ({r.stdout.strip()!r})")
subprocess.run([TOOL, "send", "--log", L, "--ctrl-c"]); time.sleep(0.4)
ok(any(d == b"\x03" for d in got) or b"\x03" in b"".join(got), "ctrl-c reaches the board as 0x03")
r = subprocess.run([TOOL, "serve", "--port", name, "--log", L, "--allow-shared"], capture_output=True, text=True, timeout=5)
ok(r.returncode != 0 and "another serve" in r.stderr, "second serve on the same log refused")
r = subprocess.run([TOOL, "send", "--log", L, "--expect", "never-printed", "--timeout", "1", "x"], capture_output=True, text=True)
ok(r.returncode == 1, "send --expect times out with exit 1")
holder = os.open(name, os.O_RDWR | os.O_NOCTTY)
r = subprocess.run([TOOL, "serve", "--port", name, "--log", f"{T}/d.log"], capture_output=True, text=True, timeout=5)
ok(r.returncode != 0 and "open in another process" in r.stderr, "serve refuses a port another process holds")
os.close(holder)
subprocess.run([TOOL, "stop", "--log", L]); srv.wait(timeout=5)
ok(srv.returncode == 0 and not os.path.exists(L + ".pid") and b"serve stopped" in open(L, "rb").read(), "stop: clean exit, pid file removed, marker logged")
r = subprocess.run([TOOL, "send", "--log", L, "x"], capture_output=True, text=True)
ok(r.returncode != 0 and "no serve" in r.stderr, "send without a serve is refused")
sys.exit(1 if FAILS else 0)
