#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Capture one boot from a board's serial console, optionally stopping autoboot.

Opens the console, optionally runs a host command that triggers the reboot
(e.g. `ssh devel@<board> sudo systemctl reboot`), and records every byte to a
log until a pattern appears or the timeout expires.

With --stop-autoboot, the given string is sent as soon as U-Boot prints its
autoboot prompt; each --uboot command then runs at the `=>` prompt, and
--continue sends `boot` afterwards. The U-Boot autoboot window is a few
seconds, which interactive serial tools and MCP round-trips tend to miss.

Without --stop-autoboot nothing is written to the console.

A second process holding the port (tio, minicom, screen) splits the incoming
bytes between readers and both logs come out with holes; the tool refuses to
start in that case unless --allow-shared is given.

Examples:
  # passive capture of a reboot
  serial-boot-capture.py --port /dev/ttyUSB0 --log boot.log \\
      --trigger 'ssh devel@<board> sudo systemctl reboot'

  # read a register at the U-Boot prompt, then boot on
  serial-boot-capture.py --port /dev/ttyUSB0 --log uboot.log \\
      --trigger 'ssh devel@<board> sudo systemctl reboot' \\
      --stop-autoboot edge --uboot 'md.l 0x11020A00 1' --continue
"""
import argparse
import os
import re
import select
import shlex
import subprocess
import sys
import termios
import time

BAUDS = {9600: termios.B9600, 57600: termios.B57600, 115200: termios.B115200,
         230400: termios.B230400, 460800: termios.B460800, 921600: termios.B921600}


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
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = BAUDS[baud]
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


class Console:
    def __init__(self, fd, log):
        self.fd, self.log, self.buf = fd, log, b''

    def read_until(self, pattern, timeout):
        """Read until regex `pattern` matches new output; True on match."""
        rx = re.compile(pattern.encode(), re.M)
        start, t0 = len(self.buf), time.time()
        while time.time() - t0 < timeout:
            if select.select([self.fd], [], [], 0.05)[0]:
                d = os.read(self.fd, 4096)
                self.buf += d
                self.log.write(d)
                self.log.flush()
            if rx.search(self.buf[start:]):
                return True
        return False

    def send(self, data):
        os.write(self.fd, data)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--port', required=True, help='serial device, e.g. /dev/ttyUSB0')
    ap.add_argument('--baud', type=int, default=115200, choices=sorted(BAUDS))
    ap.add_argument('--log', required=True, help='raw capture file (written binary)')
    ap.add_argument('--trigger', help='host command run after the port is open (starts the reboot)')
    ap.add_argument('--until', default=r'login: ?$',
                    help='regex ending the capture (default: a login prompt)')
    ap.add_argument('--timeout', type=float, default=240, help='seconds (default 240)')
    ap.add_argument('--stop-autoboot', metavar='STRING',
                    help='send STRING when U-Boot prints its autoboot prompt')
    ap.add_argument('--autoboot-prompt', default=r'(?i)autoboot',
                    help='regex for the autoboot prompt (default: "autoboot")')
    ap.add_argument('--uboot', action='append', default=[], metavar='CMD',
                    help='U-Boot command to run after stopping autoboot (repeatable)')
    ap.add_argument('--continue', dest='cont', action='store_true',
                    help="send 'boot' after the --uboot commands")
    ap.add_argument('--allow-shared', action='store_true',
                    help='start even if another process has the port open')
    args = ap.parse_args()

    if (args.uboot or args.cont) and not args.stop_autoboot:
        ap.error('--uboot/--continue need --stop-autoboot')

    others = holders(args.port)
    if others and not args.allow_shared:
        for pid, cmd in others:
            print(f'port held by pid {pid}: {cmd}', file=sys.stderr)
        sys.exit(f'{args.port} is open in another process; close it or pass --allow-shared')

    fd = open_raw(args.port, args.baud)
    rc = 1
    with open(args.log, 'wb') as log:
        con = Console(fd, log)
        if args.trigger:
            subprocess.Popen(shlex.split(args.trigger),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.time()
        if args.stop_autoboot:
            if not con.read_until(args.autoboot_prompt, args.timeout):
                print('autoboot prompt not seen', file=sys.stderr)
                os.close(fd)
                sys.exit(2)
            con.send(args.stop_autoboot.encode())
            if not con.read_until(r'=> ?$', 10):
                print('U-Boot prompt not reached after stopping autoboot', file=sys.stderr)
                os.close(fd)
                sys.exit(2)
            for cmd in args.uboot:
                con.send(cmd.encode() + b'\r')
                con.read_until(r'=> ?$', 30)
            if not args.cont:
                print(f'stopped at U-Boot prompt; {len(con.buf)} B logged to {args.log}')
                os.close(fd)
                return 0
            con.send(b'boot\r')
        remaining = max(args.timeout - (time.time() - t0), 1)
        seen = con.read_until(args.until, remaining)
        rc = 0 if seen else 1
        print(f'captured {len(con.buf)} B in {time.time() - t0:.0f}s; '
              f'end pattern {"seen" if seen else "NOT seen"} -> {args.log}')
    os.close(fd)
    return rc


if __name__ == '__main__':
    sys.exit(main())
