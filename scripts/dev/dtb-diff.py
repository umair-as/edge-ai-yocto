#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Node-level diff of two device trees, for source ref bumps.

Each input is a flattened DTB or a UKI (.efi), whose .dtb section is read.
Prints the nodes only in NEW (top of each added subtree), the nodes only in
OLD, and the nodes in both whose effective status, reg or compatible differ.
A node's effective status is "okay" when neither it nor any ancestor has a
status other than "okay"/"ok"; a missing status counts as okay.

Exit status:
  0  no node becomes enabled, or every one is listed in --accept
  1  a node is added enabled, or an existing node becomes enabled, and is not
     listed in --accept
  2  bad input, including OLD and NEW with identical bytes: a symlinked
     "old" DTB in a deploy directory resolves to the new one

--accept FILE lists node paths, one per line ('#' starts a comment). An
accepted path also covers the nodes below it.

  scripts/dev/dtb-diff.py [--accept FILE] OLD NEW
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
COMPARED = ("reg", "compatible")
# Firmware edits these at boot, and they carry no device state.
IGNORED_TOP = ("/chosen", "/__symbols__", "/__fixups__", "/__local_fixups__")


class InputError(Exception):
    pass


def _align4(n: int) -> int:
    return (n + 3) & ~3


def parse_fdt(blob: bytes) -> dict[str, dict[str, bytes]]:
    """Map every node path to its properties (raw values)."""
    if len(blob) < 40:
        raise InputError("too short for an FDT header")
    magic, total, off_struct, off_strings = struct.unpack_from(">4I", blob, 0)
    if magic != FDT_MAGIC:
        raise InputError("not a flattened device tree (bad magic)")
    if total > len(blob):
        raise InputError("FDT header size exceeds the data")
    size_strings, size_struct = struct.unpack_from(">2I", blob, 32)
    strings = blob[off_strings : off_strings + size_strings]
    pos, end = off_struct, off_struct + size_struct
    nodes: dict[str, dict[str, bytes]] = {}
    stack: list[str] = []
    while pos < end:
        (token,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if token == FDT_BEGIN_NODE:
            nul = blob.index(b"\0", pos)
            name = blob[pos:nul].decode("ascii", "replace")
            pos = _align4(nul + 1)
            stack.append(name)
            path = "/" + "/".join(s for s in stack if s)
            nodes[path] = {}
        elif token == FDT_END_NODE:
            if not stack:
                raise InputError("unbalanced FDT_END_NODE")
            stack.pop()
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from(">2I", blob, pos)
            pos += 8
            value = blob[pos : pos + length]
            pos = _align4(pos + length)
            pname = strings[nameoff : strings.index(b"\0", nameoff)].decode(
                "ascii", "replace"
            )
            if not stack:
                raise InputError("property outside a node")
            nodes["/" + "/".join(s for s in stack if s)][pname] = value
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            raise InputError(f"unknown FDT token {token:#x} at offset {pos - 4}")
    return nodes


def pe_section(blob: bytes, wanted: str) -> bytes | None:
    """Contents of a named PE/COFF section, or None when absent."""
    if blob[:2] != b"MZ":
        return None
    (pe,) = struct.unpack_from("<I", blob, 0x3C)
    if blob[pe : pe + 4] != b"PE\0\0":
        return None
    (nsections,) = struct.unpack_from("<H", blob, pe + 6)
    (opt_size,) = struct.unpack_from("<H", blob, pe + 20)
    table = pe + 24 + opt_size
    for i in range(nsections):
        off = table + 40 * i
        name = blob[off : off + 8].rstrip(b"\0").decode("ascii", "replace")
        vsize, _vaddr, rsize, rptr = struct.unpack_from("<4I", blob, off + 8)
        if name == wanted:
            size = min(vsize, rsize) if vsize else rsize
            return blob[rptr : rptr + size]
    return None


def load(path: Path) -> bytes:
    """The DTB bytes of a .dtb file or of a UKI's .dtb section."""
    try:
        blob = path.read_bytes()
    except OSError as exc:
        raise InputError(f"{path}: {exc.strerror}") from exc
    if blob[:2] == b"MZ":
        section = pe_section(blob, ".dtb")
        if section is None:
            raise InputError(f"{path}: PE file without a .dtb section")
        blob = section
    (total,) = struct.unpack_from(">I", blob, 4) if len(blob) >= 8 else (0,)
    return blob[:total] if total else blob


def status_okay(props: dict[str, bytes]) -> bool:
    value = props.get("status")
    return value is None or value.rstrip(b"\0") in (b"okay", b"ok")


def effective(nodes: dict[str, dict[str, bytes]]) -> dict[str, bool]:
    """Effective enabled state of every node (parents before children)."""
    state: dict[str, bool] = {}
    for path in sorted(nodes, key=lambda p: p.count("/") if p != "/" else 0):
        parent = path.rsplit("/", 1)[0] or "/"
        inherited = True if path == "/" else state.get(parent, True)
        state[path] = inherited and status_okay(nodes[path])
    return state


def fmt(value: bytes | None) -> str:
    if value is None:
        return "-"
    parts = value.split(b"\0")
    if value.endswith(b"\0") and all(
        p and all(32 <= c < 127 for c in p) for p in parts[:-1]
    ):
        return ",".join(f'"{p.decode()}"' for p in parts[:-1])
    if len(value) % 4 == 0:
        cells = struct.unpack(f">{len(value) // 4}I", value)
        return "<" + " ".join(f"0x{v:x}" for v in cells) + ">"
    return value.hex()


def ignored(path: str) -> bool:
    return any(path == top or path.startswith(top + "/") for top in IGNORED_TOP)


def covered(path: str, accepted: set[str]) -> bool:
    return any(path == a or path.startswith(a.rstrip("/") + "/") for a in accepted)


def diff(
    old: dict[str, dict[str, bytes]],
    new: dict[str, dict[str, bytes]],
    accepted: set[str],
) -> tuple[list[str], list[str]]:
    """Report lines and the enabled nodes that are not accepted."""
    old_on, new_on = effective(old), effective(new)
    added = {p for p in new if p not in old and not ignored(p)}
    removed = {p for p in old if p not in new and not ignored(p)}
    lines: list[str] = []
    failing: list[str] = []

    def top(paths: set[str]) -> list[str]:
        return sorted(p for p in paths if (p.rsplit("/", 1)[0] or "/") not in paths)

    for path in top(added):
        on = new_on[path]
        mark = "accepted" if covered(path, accepted) else ("NEW ENABLED" if on else "")
        lines.append(
            "added    {}  [{}] compatible={} reg={} {}".format(
                path,
                "okay" if on else "disabled",
                fmt(new[path].get("compatible")),
                fmt(new[path].get("reg")),
                mark,
            )
        )
        if on and not covered(path, accepted):
            failing.append(path)
    for path in top(removed):
        lines.append(f"removed  {path}")
    for path in sorted(set(old) & set(new)):
        if ignored(path) or path.startswith("/memory"):
            continue
        if old_on[path] != new_on[path]:
            enabled = new_on[path]
            mark = (
                "accepted"
                if covered(path, accepted)
                else ("NEWLY ENABLED" if enabled else "")
            )
            lines.append(
                "status   {}  {} -> {} {}".format(
                    path,
                    "okay" if old_on[path] else "disabled",
                    "okay" if enabled else "disabled",
                    mark,
                )
            )
            if enabled and not covered(path, accepted):
                failing.append(path)
        for prop in COMPARED:
            if old[path].get(prop) != new[path].get(prop):
                old_v, new_v = fmt(old[path].get(prop)), fmt(new[path].get(prop))
                lines.append(f"{prop:<8} {path}  {old_v} -> {new_v}")
    return lines, failing


def read_accept(path: Path | None) -> set[str]:
    if path is None:
        return set()
    entries = set()
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("old", type=Path, help="previous DTB or UKI")
    parser.add_argument("new", type=Path, help="new DTB or UKI")
    parser.add_argument("--accept", type=Path, help="reviewed node paths, one per line")
    args = parser.parse_args(argv)
    try:
        old_blob, new_blob = load(args.old), load(args.new)
        if old_blob == new_blob:
            raise InputError(
                f"OLD and NEW are byte-identical ({args.old}, {args.new}); a deploy-directory "
                "symlink resolves to the latest build"
            )
        old, new = parse_fdt(old_blob), parse_fdt(new_blob)
        accepted = read_accept(args.accept)
    except (InputError, OSError, struct.error, ValueError) as exc:
        print(f"dtb-diff: {exc}", file=sys.stderr)
        return 2
    lines, failing = diff(old, new, accepted)
    only_new = len([p for p in new if p not in old and not ignored(p)])
    only_old = len([p for p in old if p not in new and not ignored(p)])
    print(
        f"dtb-diff: {args.old} -> {args.new}: {only_new} node(s) only in NEW, {only_old} only in OLD"
    )
    for line in lines:
        print("  " + line.rstrip())
    if failing:
        print(f"FAIL: {len(failing)} enabled node(s) not in the accept list:")
        for path in failing:
            print("  " + path)
        return 1
    print("OK: no unreviewed node becomes enabled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
