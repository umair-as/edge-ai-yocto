#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host self-test for scripts/dev/serial-console-tee.py on a pseudo-terminal pair:
board output reaches the log, `send --expect` returns the reply with escapes
stripped, Ctrl-C arrives as 0x03, a second serve on the same log and a port held
by another process are refused, `stop` exits cleanly, `send` without a serve is
refused. A scripted fake board covers the board-driving subcommands: wait-boot
(facts, panic, timeout), stop-autoboot (stop string taken from the countdown line,
not interruptible), uboot (reply capture, destructive refusal, hwpart names), ip,
offset/--since, status. Exit 0 when every case passes.

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
# ---- board-driving subcommands against a scripted board ----
m2, sl2 = pty.openpty(); name2 = os.ttyname(sl2)
L2 = f"{T}/b.log"
ST = {"mode": "linux", "rx": b"", "sent": []}
def out(b): os.write(m2, b)
def fake_board():
    while True:
        try: d = os.read(m2, 1024)
        except OSError: return
        ST["rx"] += d; ST["sent"].append(d)
        if ST["mode"] == "countdown" and ST["stop"].encode() in ST["rx"]:
            ST["mode"] = "uboot"; ST["rx"] = b""; out(b"<INTERRUPT>\r\n=> ")
        elif ST["mode"] == "uboot" and d.endswith(b"\r"):
            line = ST["rx"].split(b"\r")[-2] if ST["rx"].count(b"\r") else b""
            out(d + b"\n")
            if line.startswith(b"mmc dev"):
                out(b"mmc0(part 2) is current device\r\n")
            out(b"=> ")
        elif ST["mode"] == "linux" and b"/sbin/ip -4 -br addr\r" in d:
            out(b"/sbin/ip -4 -br addr\r\nlo UNKNOWN 127.0.0.1/8\r\neth1 UP 198.51.100.5/24 \r\ndevel@edge:~$ ")
        elif ST["mode"] == "linux" and b"ip -4 -br addr\r" in d:   # non-root PATH lacks /sbin
            out(b"ip -4 -br addr\r\n-sh: ip: command not found\r\ndevel@edge:~$ ")
threading.Thread(target=fake_board, daemon=True).start()
def boot(stop="edge", countdown=True, tail=b"edge-test login: ", delay=0.6):
    def run():
        time.sleep(delay)
        out(b"NOTICE:  BL2: v2.10.5(release)\r\nU-Boot 2024.07 (Sep 25 2025)\r\n[EDGE] UBOOT boot-source=emmc\r\n")
        if countdown:
            ST.update(mode="countdown", stop=stop, rx=b"")
            out(f"Type '{stop}' within 3 seconds to stop autoboot\r\n".encode())
            t0 = time.time()
            while ST["mode"] == "countdown" and time.time() - t0 < 2: time.sleep(0.05)
            if ST["mode"] == "uboot": return
        ST["mode"] = "linux"
        out(b"   Verifying Hash Integrity ... sha256,rsa4096:k+ OK\r\nStarting kernel ...\r\n" + tail)
    threading.Thread(target=run, daemon=True).start()
def tool(*a, t=20):
    return subprocess.run([TOOL, *a], capture_output=True, text=True, timeout=t)
srv2 = subprocess.Popen([TOOL, "serve", "--port", name2, "--log", L2, "--allow-shared"]); time.sleep(1)
off = tool("offset", "--log", L2).stdout.strip()
ok(off.isdigit(), "offset prints the log size")
boot(countdown=False)
r = tool("wait-boot", "--log", L2, "--since", off, "--timeout", "10")
ok(r.returncode == 0 and "boot-source: emmc" in r.stdout and "bl2: NOTICE:  BL2: v2.10.5" in r.stdout
   and "fit: Verifying Hash Integrity" in r.stdout and "reached: login" in r.stdout, f"wait-boot reports the boot facts ({r.returncode})")
boot(countdown=False, tail=b"Kernel panic - not syncing: x\r\n", delay=0.3)
r = tool("wait-boot", "--log", L2, "--timeout", "10")
ok(r.returncode == 3 and "panic" in r.stderr, "wait-boot exits 3 on a kernel panic")
r = tool("wait-boot", "--log", L2, "--timeout", "1")
ok(r.returncode == 1, "wait-boot exits 1 on timeout")
boot(stop="xyz")
r = tool("stop-autoboot", "--log", L2, "--timeout", "10")
ok(r.returncode == 0 and "'xyz'" in r.stdout, f"stop-autoboot types the stop string the countdown names ({r.stdout.strip()!r})")
ok(not any(b" " == x for x in ST["sent"]), "stop-autoboot never sent a bare space")
r = tool("uboot", "--log", L2, "mmc dev 0 boot1")
ok(r.returncode == 0 and b"mmc dev 0 2\r" in b"".join(ST["sent"]) and "current device" in r.stdout, f"uboot translates the hwpart name and prints the reply ({r.returncode} {r.stdout!r} {r.stderr!r})")
r = tool("uboot", "--log", L2, "mmc dev 0 1")
ok("boot0" in r.stderr, "uboot notes that hwpart 1 is boot0")
before = len(ST["sent"])
r = tool("uboot", "--log", L2, "mmc write 0x58000000 0 0xFC00")
ok(r.returncode != 0 and "destructive" in r.stderr and len(ST["sent"]) == before, "uboot refuses mmc write without --allow-destructive and sends nothing")
r = tool("uboot", "--log", L2, "mmc dev 0; mmc erase 0 0xFC00")
ok(r.returncode != 0 and "destructive" in r.stderr and len(ST["sent"]) == before, "uboot refuses a destructive command chained after ';'")
r = tool("uboot", "--log", L2, "mmc dev 0 boot0", "--allow-destructive")
ok(r.returncode == 0, "uboot with --allow-destructive and a safe command runs")
ST["mode"] = "linux"
boot(countdown=False, tail=b"edge-test login: ", delay=0.2)
tool("wait-boot", "--log", L2, "--timeout", "10")
r = tool("stop-autoboot", "--log", L2, "--since", off, "--timeout", "2")
ok(r.returncode == 3, "stop-autoboot --since judges the newest boot in the window (no countdown -> exit 3)")
boot(countdown=False, delay=0.3)
r = tool("stop-autoboot", "--log", L2, "--timeout", "10")
ok(r.returncode == 3 and "not interruptible" in r.stderr, "stop-autoboot exits 3 when the board boots without a countdown")
ST["mode"] = "linux"; out(b"\r\nroot@edge:~# ")
time.sleep(0.3)
r = tool("ip", "--log", L2)
ok(r.returncode == 0 and r.stdout.strip() == "198.51.100.5", f"ip prints the eth1 address ({r.stdout.strip()!r})")
r = tool("status", "--log", L2)
ok(r.returncode == 0 and "running" in r.stdout and "never read it" in r.stdout and "last lines" in r.stdout, "status reports serve, fifo and last lines without reading the FIFO")
r = tool("wait-boot", "--log", L2 + ".in", "--timeout", "1")
ok(r.returncode != 0 and "not a regular file" in r.stderr, "log readers refuse a FIFO")
r = tool("profiles")
ok(r.returncode == 0 and "rzv2l" in r.stdout and "raspberrypi5" in r.stdout, "profiles lists both boards")
o2 = tool("offset", "--log", L2).stdout.strip()
open(L2, "ab").write(b"\n### [00:00:00] port gone (adapter re-enumerating)\n### [00:00:03] port open\nU-Boot 2024.07\r\nedge-test login: ")
r = tool("wait-boot", "--log", L2, "--since", o2, "--timeout", "3")
ok(r.returncode == 0 and "WARNING" in r.stdout and "BL2" in r.stdout, "wait-boot warns when the adapter re-enumerated mid-boot")
subprocess.run([TOOL, "stop", "--log", L2]); srv2.wait(timeout=5)
sys.exit(1 if FAILS else 0)
