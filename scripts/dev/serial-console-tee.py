#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Share one board serial console between a person and a tool.

`serve` owns the serial port, appends every byte the board prints to a log file
and writes to the board whatever arrives on a FIFO. Anyone can watch with
`tail -f <log>`; anyone can type with `send`. It reopens the port when the
USB-serial adapter disappears and comes back (adapters powered by the board
re-enumerate on every power cycle) and marks those events in the log as
`### [HH:MM:SS] ...` lines.

  serve  (--port P | --board B) --log L [--fifo F] [--baud B] [--allow-shared]
  send   --log L [--fifo F] [--ctrl-c | --raw] [--expect RE [--timeout S]] [TEXT ...]
  stop   --log L

Board-driving subcommands read the same log and write through the same FIFO, so
a session never needs its own watcher script. `--since` is a byte offset into the
log (`offset` prints the current end), `now` (default) or `start`:

  offset         print the log size
  status         serve pid, log age, last console lines (never reads the FIFO)
  profiles       print the board facts the subcommands use
  wait-boot      wait for the login prompt, print the boot facts; exit 3 on a
                 panic or FIT hash failure, 1 on timeout
  stop-autoboot  wait for the U-Boot countdown, type the stop string it names
                 until the `=>` prompt appears; exit 3 if the board booted past it
  uboot CMD...   run U-Boot commands, print each reply; destructive commands need
                 --allow-destructive, `mmc dev 0 boot0|boot1|user` is translated
  ip             print the console's IPv4 address (console must be logged in)

`send` appends a carriage return to TEXT unless --raw. With --expect it waits
until the regex matches output printed after the send, then prints that output
with escape sequences removed (exit 1 on timeout). The FIFO defaults to
<log>.in, the pid file is <log>.pid.

A second process reading the port (tio, minicom, screen, an MCP serial server)
splits the incoming bytes and both sides see holes; `serve` refuses to start
while one has the port open unless --allow-shared.

Examples:
  serial-console-tee.py serve --port /dev/serial/by-id/usb-FTDI_... --log console.log &
  tail -f console.log
  serial-console-tee.py send --log console.log --expect 'login: ' ''
  serial-console-tee.py send --log console.log --ctrl-c
  serial-console-tee.py stop --log console.log

  # reboot over ssh, then read this boot from the log
  off=$(serial-console-tee.py offset --log console.log)
  ssh devel@<board> sudo systemctl reboot
  serial-console-tee.py wait-boot --log console.log --since $off
"""
import argparse
import errno
import fcntl
import os
import re
import select
import signal
import stat
import sys
import termios
import time

BAUDS = {9600: termios.B9600, 57600: termios.B57600, 115200: termios.B115200,
         230400: termios.B230400, 460800: termios.B460800, 921600: termios.B921600}
# CSI, OSC (terminated, or cut off at the end of a read), DCS, NUL.
ESCAPES = re.compile(rb'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\|$)|\x1bP[^\x1b]*(\x1b\\|$)|\x00')


def holders(port):
    """PIDs (other than this one) with the port open, with their command line."""
    real = os.path.realpath(port)
    found = []
    for pid in filter(str.isdigit, os.listdir('/proc')):
        if int(pid) == os.getpid():
            continue
        try:
            for fd in os.listdir(f'/proc/{pid}/fd'):
                if os.path.realpath(f'/proc/{pid}/fd/{fd}') == real:
                    with open(f'/proc/{pid}/cmdline', 'rb') as f:
                        cmd = f.read().replace(b'\0', b' ').decode(errors='replace').strip()
                    found.append((pid, cmd))
                    break
        except OSError:
            continue
    return found


def open_raw(port, baud):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = BAUDS[baud]
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def write_all(fd, data, timeout=5.0):
    """Write all of data to the non-blocking port, waiting while its buffer is full."""
    t0 = time.time()
    while data:
        if not select.select([], [fd], [], 0.2)[1]:
            if time.time() - t0 > timeout:
                raise OSError(errno.ETIMEDOUT, 'port not accepting input')
            continue
        n = os.write(fd, data)
        data = data[n:]


def fifo_path(args):
    return args.fifo or args.log + '.in'


def serve(args):
    if not args.port:
        if not args.board:
            sys.exit('serve needs --port or --board')
        args.port = resolve_port(args.board)
    fifo = fifo_path(args)
    lock = open(args.log + '.pid', 'a+')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(f'another serve already uses {args.log} (see {args.log}.pid)')
    lock.seek(0)
    lock.truncate()
    lock.write(f'{os.getpid()}\n')
    lock.flush()

    others = holders(args.port) if os.path.exists(args.port) else []
    if others and not args.allow_shared:
        for pid, cmd in others:
            print(f'port held by pid {pid}: {cmd}', file=sys.stderr)
        sys.exit(f'{args.port} is open in another process; close it or pass --allow-shared')

    if not os.path.exists(fifo):
        os.mkfifo(fifo, 0o600)
    # O_RDWR keeps the FIFO open between writers, so a closing `send` is no EOF.
    fin = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    log = open(args.log, 'ab', buffering=0)

    def mark(msg):
        log.write(f'\n### [{time.strftime("%H:%M:%S")}] {msg}\n'.encode())

    def stop(signum, frame):
        mark('serve stopped')
        try:
            os.unlink(args.log + '.pid')
        except OSError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    mark(f'serve started on {args.port} at {args.baud} baud (fifo {fifo})')

    fd, ino = None, None
    while True:
        if fd is None:
            if not os.path.exists(args.port):
                time.sleep(0.05)
                continue
            try:
                fd = open_raw(args.port, args.baud)
                ino = os.stat(args.port).st_ino
                mark('port open')
            except OSError:
                time.sleep(0.2)
                continue
        try:
            gone = os.stat(args.port).st_ino != ino
        except FileNotFoundError:
            gone = True
        if gone:
            os.close(fd)
            fd = None
            mark('port gone (adapter re-enumerating)')
            continue
        try:
            ready = select.select([fd, fin], [], [], 0.2)[0]
            if fd in ready:
                data = os.read(fd, 65536)
                if data:
                    log.write(data)
            if fin in ready:
                data = os.read(fin, 4096)
                if data:
                    write_all(fd, data)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EINTR):
                continue
            try:
                os.close(fd)
            except OSError:
                pass
            fd = None
            mark(f'port error ({e.strerror}); reopening')


def send(args):
    fifo = fifo_path(args)
    if args.ctrl_c:
        data = b'\x03'
    else:
        data = ' '.join(args.text).encode()
        if not args.raw:
            data += b'\r'
    start = os.path.getsize(args.log) if os.path.exists(args.log) else 0
    try:
        out = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno in (errno.ENXIO, errno.ENOENT):
            sys.exit(f'no serve is reading {fifo}')
        raise
    os.write(out, data)
    os.close(out)
    if not args.expect:
        return 0
    rx = re.compile(args.expect.encode(), re.M)
    t0, new = time.time(), b''
    while time.time() - t0 < args.timeout:
        time.sleep(0.1)
        with open(args.log, 'rb') as f:
            f.seek(start)
            new = f.read()
        if rx.search(ESCAPES.sub(b'', new)):
            sys.stdout.write(ESCAPES.sub(b'', new).decode(errors='replace'))
            return 0
    sys.stdout.write(ESCAPES.sub(b'', new).decode(errors='replace'))
    print(f'\n[expect {args.expect!r} not seen within {args.timeout:.0f}s]', file=sys.stderr)
    return 1


def stop(args):
    try:
        with open(args.log + '.pid') as f:
            pid = int(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        sys.exit(f'no serve pid file for {args.log}')
    os.kill(pid, signal.SIGTERM)
    return 0

# Board facts mirror the build's U-Boot config and [EDGE] markers. The stop
# string is read from the countdown line; STOP_DEFAULT is only the fallback.
# Adapter globs match vendor and model, never a serial number.
STOP_DEFAULT = 'edge'
PROFILES = {
    'rzv2l': {
        'port_glob': '/dev/serial/by-id/usb-FTDI_FT230X*',
        'boot_source_values': 'qspi|esd|emmc',
        'note': 'boot source from SW11 (see docs/dev/bootchain/rzv2l.md); BL2 text precedes U-Boot',
    },
    'raspberrypi5': {
        'port_glob': '/dev/serial/by-id/usb-1a86_USB_Single_Serial*',
        'boot_source_values': 'sd|nvme|usb',
        'note': 'no BL2; firmware and U-Boot banners only',
    },
}
AUTOBOOT_RX = re.compile(r"Type '([^']+)' within \d+ seconds to stop autoboot|Hit any key to stop autoboot")
PROMPT_RX = re.compile(r'(?:^|[\r\n])=> ?$')
LOGIN_RX = re.compile(r'^(?!Last )\S+ login: ?', re.M)
BOOTED_PAST_RX = re.compile(r'## Loading kernel|Starting kernel|Booting Linux')
FAIL_RX = re.compile(r'Kernel panic - not syncing|Bad Data Hash|Bad hash|Unsupported hash|Verifying Hash Integrity[^\n]*(?:BAD|Bad|FAIL)')
FACT_RXS = [
    ('bl2', re.compile(r'^NOTICE:  BL2: v[^\n]*', re.M)),
    ('u-boot', re.compile(r'^U-Boot \d{4}\.\d{2}[^\n]*', re.M)),
    ('edge', re.compile(r'^\[EDGE\][^\n]*', re.M)),
    ('fit', re.compile(r'^\s*Verifying Hash Integrity[^\n]*', re.M)),
    ('kernel', re.compile(r'^Starting kernel[^\n]*', re.M)),
]
BOOT_SOURCE_RX = re.compile(r'\[EDGE\] UBOOT boot-source=(\w+)')
# U-Boot hardware partitions of the eMMC: `mmc dev 0 1` is boot0, `2` is boot1.
HWPART = {'user': '0', 'boot0': '1', 'boot1': '2'}
DESTRUCTIVE_RX = re.compile(
    r'^\s*(?:mmc\s+(?:write|erase|partconf|bootpart|hwpartition|rst-function)\b|sf\s+(?:write|erase|update|probe\s+\S+\s+\S+\s+\S+)\b'
    r'|env\s+(?:default|save|erase)\b|saveenv\b|(?:fat|ext4)write\b|ums\b|dfu\b|nand\s+(?:write|erase)\b|erase\b)')


def resolve_port(board):
    import glob
    prof = PROFILES.get(board)
    if not prof:
        sys.exit(f'unknown board {board!r} (known: {", ".join(PROFILES)})')
    found = sorted(glob.glob(prof['port_glob']))
    if len(found) != 1:
        sys.exit(f'{board}: {len(found)} adapters match {prof["port_glob"]}; pass --port')
    return found[0]


def clean(data):
    return ESCAPES.sub(b'', data).decode(errors='replace').replace('\r\n', '\n').replace('\r', '\n')


def log_size(log):
    return os.path.getsize(log) if os.path.exists(log) else 0


def read_log(log, start):
    """Bytes of a regular log file from offset start; refuses FIFOs and devices."""
    st = os.stat(log)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(f'{log} is not a regular file')
    with open(log, 'rb') as f:
        f.seek(start)
        return f.read()


def since_offset(args):
    v = args.since
    if v == 'now':
        return log_size(args.log)
    if v == 'start':
        return 0
    try:
        return int(v)
    except ValueError:
        sys.exit(f'--since: expected an offset, "now" or "start", got {v!r}')


def fifo_write(args, data):
    fifo = fifo_path(args)
    try:
        out = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno in (errno.ENXIO, errno.ENOENT):
            sys.exit(f'no serve is reading {fifo}')
        raise
    try:
        os.write(out, data)
    finally:
        os.close(out)


def wait_text(args, start, rx, timeout, abort=None):
    """Poll the log from start until rx matches the cleaned text. Returns
    (text, which) with which in 'match', 'abort', 'timeout'."""
    t0, text = time.time(), ''
    while True:
        text = clean(read_log(args.log, start))
        if rx.search(text):
            return text, 'match'
        if abort and abort.search(text):
            return text, 'abort'
        if time.time() - t0 >= timeout:
            return text, 'timeout'
        time.sleep(0.1)


def facts(text):
    lines = []
    m = None
    for m in BOOT_SOURCE_RX.finditer(text):
        pass
    lines.append(f'boot-source: {m.group(1) if m else "not printed"}')
    if re.search(r'^### \[[\d:]+\] port (?:gone|open|error)', text, re.M):
        lines.append('WARNING: the adapter re-enumerated during this window (power cycle); the BL2/TF-A '
                     'banner is lost. Prove the chain from U-Boot markers or EXT_CSD, not BL2.')
    for name, rx in FACT_RXS:
        found = [x.group(0).strip() for x in rx.finditer(text)]
        if found:
            uniq = list(dict.fromkeys(found))
            lines.extend(f'{name}: {x[:140]}' for x in uniq)
    return lines


def cmd_offset(args):
    print(log_size(args.log))
    return 0


def cmd_status(args):
    pid = None
    try:
        with open(args.log + '.pid') as f:
            pid = int(f.read().split()[0])
        os.kill(pid, 0)
        alive = True
    except (OSError, ValueError, IndexError):
        alive = False
    print(f'serve: {"running pid " + str(pid) if alive else "not running"}')
    fifo = fifo_path(args)
    print(f'fifo: {fifo} ({"present" if os.path.exists(fifo) else "missing"}; write-only, never read it)')
    if not os.path.exists(args.log):
        print('log: missing')
        return 1
    size = log_size(args.log)
    print(f'log: {size} bytes, last write {time.time() - os.path.getmtime(args.log):.0f}s ago')
    tail = [x for x in clean(read_log(args.log, max(0, size - 4096))).split('\n') if x.strip()][-5:]
    print('last lines:')
    for x in tail:
        print('  ' + x[:140])
    return 0 if alive else 1


def cmd_profiles(args):
    print(f'stop string fallback: {STOP_DEFAULT!r} (the countdown line names the real one)')
    print(f'autoboot prompt: {AUTOBOOT_RX.pattern}')
    print(f'U-Boot prompt: {PROMPT_RX.pattern}   login: {LOGIN_RX.pattern}')
    print(f'eMMC hardware partitions: {HWPART} (mmc dev 0 <n>)')
    for name, p in PROFILES.items():
        print(f'{name}: adapter {p["port_glob"]}; boot-source {p["boot_source_values"]}; {p["note"]}')
    return 0


def cmd_wait_boot(args):
    start = since_offset(args)
    rx = {'login': LOGIN_RX, 'autoboot': AUTOBOOT_RX, 'uboot': PROMPT_RX}[args.until]
    text, which = wait_text(args, start, rx, args.timeout, abort=FAIL_RX if args.until == 'login' else None)
    for line in facts(text):
        print(line)
    if which == 'match':
        print(f'reached: {args.until}')
        return 0
    if which == 'abort':
        print(f'FAIL: {FAIL_RX.search(text).group(0)[:140]}', file=sys.stderr)
        return 3
    print(f'[{args.until} not seen within {args.timeout:.0f}s]', file=sys.stderr)
    return 1


def cmd_stop_autoboot(args):
    start = since_offset(args)
    text, which = wait_text(args, start, AUTOBOOT_RX, args.timeout, abort=BOOTED_PAST_RX)
    if which == 'abort':
        print('board booted past U-Boot without a countdown (not interruptible, or the window was missed)',
              file=sys.stderr)
        return 3
    if which == 'timeout':
        print(f'[no autoboot countdown within {args.timeout:.0f}s]', file=sys.stderr)
        return 1
    m = AUTOBOOT_RX.search(text)
    key = args.stop_string or m.group(1) or ' '
    t0 = time.time()
    while time.time() - t0 < args.attempts_for:
        fifo_write(args, key.encode())
        time.sleep(0.3)
        tail = clean(read_log(args.log, start))
        tail = tail[AUTOBOOT_RX.search(tail).end():] if AUTOBOOT_RX.search(tail) else tail
        if PROMPT_RX.search(tail):
            print(f'U-Boot prompt reached (stop string {key!r})')
            return 0
        if BOOTED_PAST_RX.search(tail):
            print(f'board booted past the countdown despite {key!r}', file=sys.stderr)
            return 3
    print(f'sent {key!r} for {args.attempts_for:.0f}s, no U-Boot prompt', file=sys.stderr)
    return 2


def translate_uboot(cmd):
    """`mmc dev 0 boot1` -> `mmc dev 0 2`."""
    m = re.match(r'^(\s*mmc\s+dev\s+\d+\s+)(user|boot0|boot1)\b(.*)$', cmd)
    if m:
        return m.group(1) + HWPART[m.group(2)] + m.group(3)
    return cmd


def cmd_uboot(args):
    if not args.commands:
        sys.exit('uboot needs at least one command')
    cmds = [translate_uboot(c) for c in args.commands]
    for c in cmds:
        # U-Boot runs ';'-separated commands on one line; check each of them.
        if any(DESTRUCTIVE_RX.search(part) for part in c.split(';')) and not args.allow_destructive:
            sys.exit(f'refusing {c!r}: destructive, pass --allow-destructive')
        if re.match(r'^\s*mmc\s+dev\s+\d+\s+[12]\b', c):
            print('note: hardware partition 1 = boot0, 2 = boot1', file=sys.stderr)
    start = log_size(args.log)
    if not PROMPT_RX.search(clean(read_log(args.log, max(0, start - 64)))):
        sys.exit('console is not at a U-Boot prompt (run stop-autoboot first)')
    for c in cmds:
        mark = log_size(args.log)
        fifo_write(args, c.encode() + b'\r')
        text, which = wait_text(args, mark, re.compile(r'\n=> ?$'), args.timeout)
        body = text.split('\n', 1)[1] if '\n' in text else text
        print(f'=> {c}')
        print(re.sub(r'\n?=> ?$', '', body).rstrip())
        if which != 'match':
            print(f'[no prompt after {c!r} within {args.timeout:.0f}s]', file=sys.stderr)
            return 1
    return 0


def cmd_ip(args):
    mark = log_size(args.log)
    # /sbin/ip: not on a non-root PATH on every image; present on both boards.
    fifo_write(args, b'/sbin/ip -4 -br addr\r')
    rx = re.compile(r'^(\S+)\s+\S+\s+(\d+\.\d+\.\d+\.\d+)/\d+', re.M)
    t0, text = time.time(), ''
    while time.time() - t0 < args.timeout:
        time.sleep(0.3)
        text = clean(read_log(args.log, mark))
        hits = [(m.group(1), m.group(2)) for m in rx.finditer(text) if m.group(1) != 'lo']
        if args.iface:
            hits = [h for h in hits if h[0] == args.iface]
        if hits and text.rstrip().endswith(('#', '$')):
            print(hits[0][1])
            return 0
    why = 'console is at a login prompt, not logged in' if LOGIN_RX.search(text) else 'no address in the reply'
    print(f'[{why}]', file=sys.stderr)
    return 1



def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('serve', help='own the port, log output, forward the FIFO')
    s.add_argument('--port', help='serial device; a /dev/serial/by-id path survives re-enumeration')
    s.add_argument('--board', choices=sorted(PROFILES), help='resolve --port from the board profile')
    s.add_argument('--baud', type=int, default=115200, choices=sorted(BAUDS))
    s.add_argument('--log', required=True, help='console log, appended raw')
    s.add_argument('--fifo', help='input FIFO (default: <log>.in)')
    s.add_argument('--allow-shared', action='store_true',
                   help='start even if another process has the port open')

    t = sub.add_parser('send', help='type into the console')
    t.add_argument('--log', required=True, help='the log of the running serve')
    t.add_argument('--fifo', help='input FIFO (default: <log>.in)')
    g = t.add_mutually_exclusive_group()
    g.add_argument('--ctrl-c', action='store_true', help='send Ctrl-C (0x03) only')
    g.add_argument('--raw', action='store_true', help='do not append a carriage return')
    t.add_argument('--expect', metavar='RE', help='wait for this regex in the new output and print it')
    t.add_argument('--timeout', type=float, default=30, help='seconds for --expect (default 30)')
    t.add_argument('text', nargs='*', help='text to send (joined with spaces)')

    p = sub.add_parser('stop', help='stop the serve of a log')
    p.add_argument('--log', required=True)

    def common(sp, since=False):
        sp.add_argument('--log', required=True, help='the log of the running serve')
        sp.add_argument('--fifo', help='input FIFO (default: <log>.in)')
        sp.add_argument('--board', choices=sorted(PROFILES), default=os.environ.get('BOARD') if os.environ.get('BOARD') in PROFILES else None)
        if since:
            sp.add_argument('--since', default='now', help='byte offset, "now" (default) or "start"')

    common(sub.add_parser('offset', help='print the log size'))
    common(sub.add_parser('status', help='serve and log state'))
    sub.add_parser('profiles', help='print the board facts')
    w = sub.add_parser('wait-boot', help='wait for a boot stage, print the boot facts')
    common(w, True)
    w.add_argument('--until', choices=['login', 'autoboot', 'uboot'], default='login')
    w.add_argument('--timeout', type=float, default=240)
    a = sub.add_parser('stop-autoboot', help='stop the U-Boot countdown')
    common(a, True)
    a.add_argument('--timeout', type=float, default=900, help='seconds to wait for the countdown')
    a.add_argument('--stop-string', help='override the string the countdown names')
    a.add_argument('--attempts-for', type=float, default=10, help='seconds to keep typing the stop string')
    u = sub.add_parser('uboot', help='run U-Boot commands at the prompt')
    common(u)
    u.add_argument('--allow-destructive', action='store_true')
    u.add_argument('--timeout', type=float, default=30)
    u.add_argument('commands', nargs='*', metavar='CMD')
    i = sub.add_parser('ip', help='print the console IPv4 address')
    common(i)
    i.add_argument('--iface')
    i.add_argument('--timeout', type=float, default=10)

    args = ap.parse_args()
    table = {'serve': serve, 'send': send, 'stop': stop, 'offset': cmd_offset, 'status': cmd_status,
             'profiles': cmd_profiles, 'wait-boot': cmd_wait_boot, 'stop-autoboot': cmd_stop_autoboot,
             'uboot': cmd_uboot, 'ip': cmd_ip}
    return table[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
