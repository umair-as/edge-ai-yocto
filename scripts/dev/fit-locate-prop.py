#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Print the file offset and length of one property value in a FIT or DTB.

Read-only. Output is "<offset> <length>" in bytes, for building byte-level
test fixtures (fit-verifier-fixtures.sh) without a libfdt dependency.

  fit-locate-prop.py fitImage /images/kernel-1 data
  fit-locate-prop.py fitImage /configurations/conf-A description
"""
import struct
import sys

FDT_MAGIC = 0xd00dfeed
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def locate(blob, want_node, want_prop):
    magic, _size, off_struct, off_strings = struct.unpack('>IIII', blob[:16])
    if magic != FDT_MAGIC:
        raise ValueError('not a flattened device tree (bad magic)')

    def cstr(o):
        return blob[o:blob.index(b'\0', o)].decode()

    path, p = [], off_struct
    while True:
        tok = struct.unpack('>I', blob[p:p + 4])[0]
        p += 4
        if tok == FDT_BEGIN_NODE:
            name = cstr(p)
            p += (len(name) + 4) & ~3
            path.append(name)
        elif tok == FDT_END_NODE:
            path.pop()
        elif tok == FDT_PROP:
            ln, nameoff = struct.unpack('>II', blob[p:p + 8])
            p += 8
            node = '/' + '/'.join(x for x in path if x)
            if node == want_node and cstr(off_strings + nameoff) == want_prop:
                return p, ln
            p += (ln + 3) & ~3
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            return None
        else:
            raise ValueError(f'unexpected FDT token {tok:#x} at {p - 4}')


def main():
    if len(sys.argv) != 4:
        sys.exit(f'usage: {sys.argv[0]} <fit|dtb> <node-path> <property>')
    with open(sys.argv[1], 'rb') as f:
        blob = f.read()
    hit = locate(blob, sys.argv[2], sys.argv[3])
    if hit is None:
        sys.exit(f'{sys.argv[2]}:{sys.argv[3]} not found')
    print(*hit)


if __name__ == '__main__':
    main()
