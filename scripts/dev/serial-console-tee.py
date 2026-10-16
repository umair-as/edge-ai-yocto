#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Share one board serial console between a person and a tool.

`serve` owns the serial port, appends every byte the board prints to a log file
and writes to the board whatever arrives on a FIFO. Anyone can watch with
`tail -f <log>`; anyone can type with `send`. It reopens the port when the
USB-serial adapter disappears and comes back (adapters powered by the board
re-enumerate on every power cycle) and marks those events in the log as
`### [HH:MM:SS] ...` lines.

  serve  --port P --log L [--fifo F] [--baud B] [--allow-shared]
  send   --log L [--fifo F] [--ctrl-c | --raw] [--expect RE [--timeout S]] [TEXT ...]
  stop   --log L

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
"""
import argparse
import errno
import fcntl
import os
import re
import select
import signal
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
                time.sleep(0.2)
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('serve', help='own the port, log output, forward the FIFO')
    s.add_argument('--port', required=True, help='serial device; a /dev/serial/by-id path survives re-enumeration')
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

    args = ap.parse_args()
    return {'serve': serve, 'send': send, 'stop': stop}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
