#!/usr/bin/env python3
"""Kernel-hardening gate: run kernel-hardening-checker on an expanded kernel
.config and fail on any FAIL that the committed baseline does not accept.

The baseline maps each accepted failing option to the reason it is accepted.
A reason is a non-empty string; anything else is not a reason: the gate
rejects it, and --update writes new failures with an empty reason and exits 1
so the operator has to fill them in before the baseline is valid. The baseline
also records the checker version that produced it; a run with a different
version is refused, since the rule set differs. Accepted entries that now pass
are reported; they never fail the gate.

Input must be the expanded .config produced by the kernel's configure step
("# Linux/<arch> <ver> Kernel Configuration" header). A defconfig or a Yocto
.cfg fragment is not enough: the checker cannot detect arch/version from it
and Kconfig defaults are not materialised.

Usage:
  khc-gate.py --config <.config> --baseline <baseline.json> [--report out.md]
  khc-gate.py --config <.config> --baseline <baseline.json> --update

Exit codes: 0 pass, 1 regression or incomplete baseline, 2 usage / tool error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
from pathlib import Path

TOOL = "kernel-hardening-checker"


def die(msg: str, code: int = 2) -> None:
    print(f"[khc-gate] ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def tool_version() -> str:
    out = subprocess.run([TOOL, "--version"], capture_output=True, text=True, check=False)
    text = (out.stdout or out.stderr).strip()
    return text.split()[-1] if text else "unknown"


def run_checker(config: Path, extra: list[str]) -> list[dict]:
    cmd = [TOOL, "-c", str(config), "-m", "json", *extra]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0 or not proc.stdout.strip():
        die(
            f"{TOOL} failed (rc={proc.returncode}): {proc.stderr.strip()}\n"
            "The input must be an expanded .config from the build "
            "(bitbake virtual/kernel -c configure), not a fragment or defconfig."
        )
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        die(f"could not parse checker JSON: {exc}")
    if not isinstance(rows, list):
        die("checker JSON is not a list")
    return rows


def failing(rows: list[dict]) -> dict[str, str]:
    """option_name -> check_result for every FAIL row."""
    return {
        r["option_name"]: r["check_result"]
        for r in rows
        if not r.get("check_result_bool", False)
    }


def has_reason(v: object) -> bool:
    return isinstance(v, str) and bool(v.strip())


def load_baseline(path: Path) -> dict[str, str]:
    if not path.exists():
        die(f"baseline {path} not found; create it with --update")
    with path.open() as fh:
        data = json.load(fh)
    accepted = data.get("accepted_failures")
    if not isinstance(accepted, dict):
        die(f"{path}: 'accepted_failures' must map option name -> reason")
    # The baseline is only meaningful against the rule set that produced it.
    recorded, current = data.get("tool_version"), tool_version()
    if recorded != current:
        die(
            f"{path} was recorded with {TOOL} {recorded}, this run uses {current}; "
            "install the pinned version or re-baseline with --update"
        )
    empty = sorted(k for k, v in accepted.items() if not has_reason(v))
    if empty:
        die(
            f"{path}: {len(empty)} accepted failure(s) without a reason: "
            + ", ".join(empty),
            code=1,
        )
    return accepted


def write_baseline(path: Path, accepted: dict[str, str], config: Path) -> None:
    data = {
        "_comment": (
            "Options kernel-hardening-checker reports as FAIL that this platform "
            "accepts, each with the reason. Regenerate with "
            "scripts/ci/khc-gate.py --update, then fill in every empty reason."
        ),
        "tool": TOOL,
        "tool_version": tool_version(),
        "config": config.name,
        "generated": dt.date.today().isoformat(),
        "accepted_failures": dict(sorted(accepted.items())),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def write_report(
    path: Path,
    config: Path,
    rows: list[dict],
    fails: dict[str, str],
    regressions: dict[str, str],
    fixed: list[str],
    accepted: dict[str, str],
) -> None:
    ok = sum(1 for r in rows if r.get("check_result_bool"))
    lines = [
        f"# kernel-hardening-checker — `{config.name}`",
        "",
        f"- tool: {TOOL} {tool_version()}",
        f"- checks: {len(rows)} · OK: {ok} · FAIL: {len(fails)} · accepted: {len(accepted)}",
        f"- regressions: {len(regressions)} · newly passing: {len(fixed)}",
        "",
    ]
    if regressions:
        lines += ["## Regressions", ""]
        lines += [f"- `{k}` — {v}" for k, v in sorted(regressions.items())]
        lines.append("")
    if fixed:
        lines += ["## Newly passing (tighten the baseline with --update)", ""]
        lines += [f"- `{k}`" for k in sorted(fixed)]
        lines.append("")
    lines += ["## Accepted failures", ""]
    lines += [f"- `{k}` — {accepted[k]}" for k in sorted(accepted)]
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--config", required=True, type=Path, help="expanded kernel .config")
    ap.add_argument("--baseline", required=True, type=Path, help="accepted-failures JSON")
    ap.add_argument("--report", type=Path, help="write a markdown report here")
    ap.add_argument(
        "--update",
        action="store_true",
        help="rewrite the baseline from this run, keeping existing reasons; "
        "exit 1 while any reason is empty",
    )
    ap.add_argument("--kernel-version", type=Path, help="passed to the checker as -v")
    ap.add_argument("--sysctl", type=Path, help="passed to the checker as -s")
    args = ap.parse_args()

    if shutil.which(TOOL) is None:
        die(f"{TOOL} not on PATH")
    if not args.config.is_file():
        die(f"config {args.config} not found")

    extra: list[str] = []
    if args.kernel_version:
        extra += ["-v", str(args.kernel_version)]
    if args.sysctl:
        extra += ["-s", str(args.sysctl)]

    rows = run_checker(args.config, extra)
    fails = failing(rows)

    if args.update:
        previous: dict[str, str] = {}
        if args.baseline.exists():
            with args.baseline.open() as fh:
                previous = json.load(fh).get("accepted_failures", {}) or {}
        accepted = {k: (previous.get(k) if has_reason(previous.get(k)) else "") for k in fails}
        write_baseline(args.baseline, accepted, args.config)
        if args.report:
            write_report(args.report, args.config, rows, fails, {}, [], accepted)
        missing = sorted(k for k, v in accepted.items() if not has_reason(v))
        print(f"[khc-gate] baseline written: {args.baseline} ({len(accepted)} accepted failures)")
        if missing:
            print(f"[khc-gate] {len(missing)} entries need a reason before the baseline is valid:")
            for k in missing:
                print(f"    {k}: {fails[k]}")
            return 1
        return 0

    accepted = load_baseline(args.baseline)
    regressions = {k: v for k, v in fails.items() if k not in accepted}
    fixed = sorted(set(accepted) - set(fails))

    if args.report:
        write_report(args.report, args.config, rows, fails, regressions, fixed, accepted)

    ok = sum(1 for r in rows if r.get("check_result_bool"))
    print(
        f"[khc-gate] {args.config.name}: {len(rows)} checks, {ok} OK, {len(fails)} FAIL "
        f"({len(accepted)} accepted)"
    )
    for k in fixed:
        print(f"[khc-gate] now passing, drop from baseline: {k}")
    if regressions:
        print(f"[khc-gate] FAIL: {len(regressions)} regression(s) not in baseline:")
        for k, v in sorted(regressions.items()):
            print(f"    {k}: {v}")
        return 1
    print("[khc-gate] PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
