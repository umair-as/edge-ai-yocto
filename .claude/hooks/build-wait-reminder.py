#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""PostToolUse and PostToolUseFailure hook (Bash): after agent-build.py start,
remind the session to attach a background `wait` to each run it just created.
A call that exits non-zero (start chained with a failing command) reaches only
PostToolUseFailure, whose output is in `error`.

A reminder only: it adds context and never blocks. Runs are identified by the
launcher's `Run: <dir>` line, resolved against the tool call's directory, and
counted only when <dir>/run.json exists; a run with result.json has already
ended. Any internal error stays silent.
"""

import json
import re
import sys
from pathlib import Path

RUN_LINE = re.compile(r"^Run: (\S.*?)\s*$", re.MULTILINE)
# An invocation: start is followed by an option or the run topic.
START = re.compile(r"agent-build\.py\s+start\s+[-\w]")
WAIT = "python3 scripts/agent-build/agent-build.py wait"


def output_of(response):
    if isinstance(response, str):
        return response
    if isinstance(response, dict):
        return "\n".join(str(response.get(key) or "") for key in ("stdout", "stderr"))
    return ""


def runs_in(text, cwd):
    """(live, ended) run directories named by Run: lines, each once, in order."""
    live, ended = [], []
    for match in RUN_LINE.finditer(text):
        run = (Path(cwd) / match.group(1)).resolve()
        if run in live or run in ended or not (run / "run.json").is_file():
            continue
        (ended if (run / "result.json").exists() else live).append(run)
    return live, ended


def reminder(payload):
    command = str((payload.get("tool_input") or {}).get("command") or "")
    text = (
        output_of(payload.get("tool_response")) + "\n" + output_of(payload.get("error"))
    )
    live, ended = runs_in(text, payload.get("cwd") or ".")
    parts = []
    if live:
        parts.append(
            "Build run(s) running. Attach each wait now as a background task (no timeout), so completion "
            "is notified; if one cannot be attached, report that run as unmonitored:\n"
            + "\n".join(f"- {WAIT} {run}" for run in live)
        )
    if ended and START.search(command):
        parts.append(
            "Run(s) already ended; read the outcome with status:\n"
            + "\n".join(f"- {WAIT.replace(' wait', ' status')} {run}" for run in ended)
        )
    if not parts and START.search(command):
        parts.append(
            "agent-build.py start ran, but no Run: line is visible in this output (redirected, trimmed or "
            "failed). Check `agent-build.py list` for a run to attach a wait to."
        )
    return "\n".join(parts) or None


def main():
    try:
        payload = json.loads(sys.stdin.read())
        text = reminder(payload)
        event = str(payload.get("hook_event_name") or "PostToolUse")
    except Exception:  # noqa: BLE001 - a reminder hook never fails the tool call
        return 0
    if text:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": text,
                    }
                }
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
