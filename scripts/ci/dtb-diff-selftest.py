#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host self-test for scripts/dev/dtb-diff.py on synthetic device trees.

Builds small FDTs in memory (no dtc needed) and checks the parser, effective
status inheritance, the accept list, UKI .dtb extraction and the
identical-input refusal.

  scripts/ci/dtb-diff-selftest.py
"""

import contextlib
import importlib.util
import io
import pathlib
import struct
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "dtb_diff", HERE.parent / "dev" / "dtb-diff.py"
)
assert spec and spec.loader
dtb_diff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dtb_diff)


def fdt(tree: dict) -> bytes:
    """Serialise {"props": {...}, "children": {name: tree}} as a DTB."""
    strings = bytearray()
    offsets: dict[str, int] = {}

    def stroff(name: str) -> int:
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return offsets[name]

    def pad(b: bytes) -> bytes:
        return b + b"\0" * ((4 - len(b) % 4) % 4)

    def node(name: str, t: dict) -> bytes:
        out = struct.pack(">I", 1) + pad(name.encode() + b"\0")
        for key, value in t.get("props", {}).items():
            if isinstance(value, str):
                value = value.encode() + b"\0"
            out += struct.pack(">3I", 3, len(value), stroff(key)) + pad(value)
        for child, sub in t.get("children", {}).items():
            out += node(child, sub)
        return out + struct.pack(">I", 2)

    body = node("", tree) + struct.pack(">I", 9)
    rsv = b"\0" * 16
    off_rsv = 40
    off_struct = off_rsv + len(rsv)
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    header = struct.pack(
        ">10I",
        0xD00DFEED,
        total,
        off_struct,
        off_strings,
        off_rsv,
        17,
        16,
        0,
        len(strings),
        len(body),
    )
    return header + rsv + body + bytes(strings)


def uki(dtb: bytes) -> bytes:
    """Minimal PE image with a .text and a .dtb section."""
    pe_off = 0x40
    nsec = 2
    opt = b"\0" * 16
    table = pe_off + 24 + len(opt)
    data_off = table + 40 * nsec
    text = b"\x90" * 8
    sections = b""
    ptr = data_off
    payload = b""
    for name, data in ((b".text", text), (b".dtb", dtb)):
        sections += name.ljust(8, b"\0") + struct.pack(
            "<4I", len(data), 0, len(data) + 7 & ~7, ptr
        )
        sections += b"\0" * 16
        chunk = data.ljust(len(data) + 7 & ~7, b"\0")
        payload += chunk
        ptr += len(chunk)
    head = bytearray(b"MZ".ljust(pe_off, b"\0"))
    struct.pack_into("<I", head, 0x3C, pe_off)
    coff = (
        b"PE\0\0"
        + struct.pack("<HH", 0xAA64, nsec)
        + b"\0" * 12
        + struct.pack("<HH", len(opt), 0)
    )
    return bytes(head) + coff + opt + sections + payload


def soc(*children: tuple[str, dict]) -> dict:
    return {
        "props": {"compatible": "test,board"},
        "children": {"soc": {"children": dict(children)}},
    }


MBOX = {
    "props": {"compatible": "qcom,ipcc", "reg": struct.pack(">2I", 0x408000, 0x1000)}
}


def run(
    old: dict | bytes, new: dict | bytes, accept: str | None = None
) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        (d / "old").write_bytes(old if isinstance(old, bytes) else fdt(old))
        (d / "new").write_bytes(new if isinstance(new, bytes) else fdt(new))
        argv = [str(d / "old"), str(d / "new")]
        if accept is not None:
            (d / "accept").write_text(accept)
            argv += ["--accept", str(d / "accept")]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = dtb_diff.main(argv)
        return code, out.getvalue() + err.getvalue()


class DtbDiffTest(unittest.TestCase):
    def test_parse_paths_and_props(self):
        nodes = dtb_diff.parse_fdt(fdt(soc(("mailbox@408000", MBOX))))
        self.assertIn("/soc/mailbox@408000", nodes)
        self.assertEqual(nodes["/soc/mailbox@408000"]["compatible"], b"qcom,ipcc\0")

    def test_added_enabled_node_fails(self):
        code, out = run(
            soc(("mailbox@408000", MBOX)),
            soc(("mailbox@408000", MBOX), ("mailbox@488000", MBOX)),
        )
        self.assertEqual(code, 1)
        self.assertIn("/soc/mailbox@488000", out.split("FAIL")[1])

    def test_added_disabled_node_passes(self):
        off = {"props": dict(MBOX["props"], status="disabled")}
        code, out = run(
            soc(("mailbox@408000", MBOX)),
            soc(("mailbox@408000", MBOX), ("mailbox@488000", off)),
        )
        self.assertEqual(code, 0, out)

    def test_child_of_disabled_parent_is_disabled(self):
        old = {"children": {"bus": {"props": {"status": "disabled"}}}}
        new = {
            "children": {
                "bus": {"props": {"status": "disabled"}, "children": {"dev@1": MBOX}}
            }
        }
        code, out = run(old, new)
        self.assertEqual(code, 0, out)

    def test_existing_node_newly_enabled_fails(self):
        off = {"props": dict(MBOX["props"], status="disabled")}
        code, out = run(soc(("mailbox@408000", off)), soc(("mailbox@408000", MBOX)))
        self.assertEqual(code, 1)
        self.assertIn("NEWLY ENABLED", out)

    def test_accept_covers_subtree(self):
        new = soc(
            ("mailbox@408000", MBOX),
            ("rpc", {"children": {"cb@5": MBOX, "cb@6": MBOX}}),
        )
        code, out = run(
            soc(("mailbox@408000", MBOX)), new, accept="# reviewed\n/soc/rpc\n"
        )
        self.assertEqual(code, 0, out)

    def test_reg_change_reported_without_failing(self):
        wide = {"props": dict(MBOX["props"], reg=struct.pack(">2I", 0x408000, 0x2000))}
        code, out = run(soc(("mailbox@408000", MBOX)), soc(("mailbox@408000", wide)))
        self.assertEqual(code, 0)
        self.assertIn("reg      /soc/mailbox@408000", out)

    def test_identical_inputs_refused(self):
        tree = soc(("mailbox@408000", MBOX))
        code, out = run(tree, tree)
        self.assertEqual(code, 2)
        self.assertIn("byte-identical", out)

    def test_uki_dtb_section(self):
        old = fdt(soc(("mailbox@408000", MBOX)))
        new = fdt(soc(("mailbox@408000", MBOX), ("mailbox@488000", MBOX)))
        code, out = run(uki(old), new)
        self.assertEqual(code, 1, out)

    def test_bad_input(self):
        code, out = run(b"not a dtb at all, padded to forty bytes....", soc())
        self.assertEqual(code, 2)
        self.assertIn("bad magic", out)

    def test_chosen_ignored(self):
        code, out = run(
            soc(),
            {
                "props": {"compatible": "test,board"},
                "children": {"soc": {}, "chosen": {"props": {"bootargs": "x"}}},
            },
        )
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
