#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compose the RZ/V2L eMMC boot-partition image (zero, BL2 at --bl2-offset,
FIP at --fip-offset) and check it at build time. Prints the bundle meta as
key=value lines. Exit 1 with a reason on any check failure.

Checks: BL2 carries the boot-parameter signature AA55 at 0x1FE and a size word
equal to its body length rounded up to 4, within the ROM's load window; the
FIP starts with ToC name 0xAA640001; BL2 ends before the FIP; the TF-A pin is in the layout table with this FIP offset; the
image fits the boot partition; the FIP holds a U-Boot DTB with FIT keys
(written to --anchor-out for the FIT trust gate)."""
import argparse
import hashlib
import struct
import subprocess
import sys

BL2_MAX = 0x1D000          # on-chip RAM 0x12000-0x2EFFF
TOC_NAME = 0xAA640001
BP_SIZE = 0x200              # bl2_bp_mmc boot-parameter block


def fail(msg):
    sys.stderr.write("rzv2l-bootchain-compose: %s\n" % msg)
    sys.exit(1)


def num(s):
    return int(s, 0)


def find_anchor(fip, fdtget):
    """First FDT in the FIP that has /signature/key-* nodes."""
    off = fip.find(b"\xd0\x0d\xfe\xed")
    while off != -1:
        size = struct.unpack(">I", fip[off + 4:off + 8])[0] if off + 8 <= len(fip) else 0
        if 64 < size < 0x100000 and off + size <= len(fip):
            blob = fip[off:off + size]
            path = args.anchor_out
            with open(path, "wb") as f:
                f.write(blob)
            r = subprocess.run([fdtget, "-l", path, "/signature"], capture_output=True, text=True)
            if r.returncode == 0 and any(n.startswith("key-") for n in r.stdout.split()):
                return True
        off = fip.find(b"\xd0\x0d\xfe\xed", off + 1)
    return False


p = argparse.ArgumentParser()
p.add_argument("--bl2", required=True)
p.add_argument("--fip", required=True)
p.add_argument("--out", required=True)
p.add_argument("--bl2-offset", type=num, required=True)
p.add_argument("--fip-offset", type=num, required=True)
p.add_argument("--bootpart-size", type=num, required=True)
p.add_argument("--tfa-pin", required=True)
p.add_argument("--layout", required=True, help='"<pin>:<fip offset> ..."')
p.add_argument("--anchor-out", required=True)
p.add_argument("--fdtget", default="fdtget")
args = p.parse_args()

bl2 = open(args.bl2, "rb").read()
fip = open(args.fip, "rb").read()

# bl2_bp = one 512-byte boot-parameter block (bptool) + bl2.bin; the block's
# size word is the body length rounded up to 4 (bptool.c, (size + 3) & ~3).
if len(bl2) < 0x200 or bl2[0x1FE:0x200] != b"\x55\xaa":
    fail("%s: no boot-parameter signature AA55 at 0x1FE" % args.bl2)
body = len(bl2) - BP_SIZE
word = struct.unpack("<I", bl2[0:4])[0]
if body <= 0 or word != (body + 3) & ~3:
    fail("%s: size word %#x does not match the %d-byte BL2 body after the boot parameters"
         % (args.bl2, word, body))
if word > BL2_MAX:
    fail("%s: BL2 body %#x exceeds the ROM load window %#x" % (args.bl2, word, BL2_MAX))
if len(fip) < 8 or struct.unpack("<I", fip[0:4])[0] != TOC_NAME:
    fail("%s: no FIP ToC name %#x" % (args.fip, TOC_NAME))
if args.bl2_offset < 0x200 or args.bl2_offset + len(bl2) > args.fip_offset:
    fail("BL2 (%d B at %#x) overlaps the FIP at %#x" % (len(bl2), args.bl2_offset, args.fip_offset))

layout = {}
for e in args.layout.split():
    pin, _, off = e.partition(":")
    layout[pin] = num(off)
if args.tfa_pin not in layout:
    fail("TF-A pin %r not in the layout table %r" % (args.tfa_pin, args.layout))
if layout[args.tfa_pin] != args.fip_offset:
    fail("TF-A pin %s reads the FIP at %#x, image places it at %#x"
         % (args.tfa_pin, layout[args.tfa_pin], args.fip_offset))

size = args.fip_offset + len(fip)
if size > args.bootpart_size:
    fail("image %d B exceeds the boot partition (%d B)" % (size, args.bootpart_size))
if not find_anchor(fip, args.fdtget):
    fail("%s: no U-Boot DTB with /signature keys (FIT anchor) in the FIP" % args.fip)

img = bytearray(size)
img[args.bl2_offset:args.bl2_offset + len(bl2)] = bl2
img[args.fip_offset:] = fip
with open(args.out, "wb") as f:
    f.write(img)

print("bl2-offset=%#x" % args.bl2_offset)
print("bl2-size=%d" % len(bl2))
print("bl2-sha256=%s" % hashlib.sha256(bl2).hexdigest())
print("fip-offset=%#x" % args.fip_offset)
print("fip-size=%d" % len(fip))
print("fip-sha256=%s" % hashlib.sha256(fip).hexdigest())
print("image-sha256=%s" % hashlib.sha256(img).hexdigest())
