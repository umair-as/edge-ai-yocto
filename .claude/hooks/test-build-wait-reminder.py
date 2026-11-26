#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Checks for the build-wait reminder hook, fed PostToolUse JSON; no tmux or build."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).with_name("build-wait-reminder.py").resolve()
START = "python3 scripts/agent-build/agent-build.py start demo -- dev BOARD=rzv2l"


def run_hook(payload):
    out = subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert out.returncode == 0, out.stderr
    if not out.stdout.strip():
        return None
    return json.loads(out.stdout)["hookSpecificOutput"]


def make_run(root, name, finished=False):
    run = root / "build/agent-runs" / name
    run.mkdir(parents=True)
    (run / "run.json").write_text("{}")
    if finished:
        (run / "result.json").write_text('{"exit_code": 0}')
    return run


def launcher_output(path):
    return f"Run: {path}\nWatch: tmux -L edge-builds attach-session -r -t build-x\n"


class ReminderTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def payload(self, command, stdout, response_as_text=False):
        response = (
            stdout
            if response_as_text
            else {"stdout": stdout, "stderr": "", "interrupted": False}
        )
        return {
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "cwd": str(self.root),
            "tool_input": {"command": command},
            "tool_response": response,
        }

    def test_one_start_names_its_run_and_the_wait(self):
        run = make_run(self.root, "20261126T100000Z-demo-aaaa")
        got = run_hook(self.payload(START, launcher_output(run)))
        self.assertEqual(got["hookEventName"], "PostToolUse")
        self.assertIn(f"agent-build.py wait {run}", got["additionalContext"])
        self.assertIn("background", got["additionalContext"])

    def test_relaunch_chain_names_every_run_once(self):
        first = make_run(self.root, "20261126T100000Z-demo-aaaa")
        second = make_run(self.root, "20261126T100100Z-demo-bbbb")
        text = (
            launcher_output(first) + launcher_output(second) + launcher_output(second)
        )
        ctx = run_hook(self.payload(START + " && " + START, text))["additionalContext"]
        self.assertEqual(
            (ctx.count(f"wait {first}"), ctx.count(f"wait {second}")), (1, 1)
        )

    def test_relative_run_path_resolves_against_cwd(self):
        run = make_run(self.root, "20261126T100000Z-demo-aaaa")
        ctx = run_hook(
            self.payload(START, launcher_output(run.relative_to(self.root)))
        )["additionalContext"]
        self.assertIn(f"wait {run}", ctx)

    def test_string_tool_response_is_read(self):
        run = make_run(self.root, "20261126T100000Z-demo-aaaa")
        got = run_hook(self.payload(START, launcher_output(run), response_as_text=True))
        self.assertIn(str(run), got["additionalContext"])

    def test_start_without_a_visible_run_line_points_to_list(self):
        for out in ("agent-build: Supply a make target\n", ""):
            with self.subTest(out=out):
                ctx = run_hook(self.payload(START + " >/dev/null", out))[
                    "additionalContext"
                ]
                self.assertIn("agent-build.py list", ctx)
                self.assertNotIn("agent-build.py wait", ctx)

    def test_start_chained_with_wait_reports_the_ended_run(self):
        run = make_run(self.root, "20261126T100000Z-demo-aaaa", finished=True)
        ctx = run_hook(
            self.payload(START + " && agent-build.py wait x", launcher_output(run))
        )["additionalContext"]
        self.assertIn(f"agent-build.py status {run}", ctx)
        self.assertNotIn("agent-build.py wait", ctx)

    def test_run_line_on_stderr_is_read(self):
        run = make_run(self.root, "20261126T100000Z-demo-aaaa")
        payload = self.payload(START, "")
        payload["tool_response"]["stderr"] = launcher_output(run)
        self.assertIn(f"wait {run}", run_hook(payload)["additionalContext"])

    def test_finished_or_unrecorded_runs_are_not_reminded(self):
        done = make_run(self.root, "20261126T090000Z-old-cccc", finished=True)
        ghost = self.root / "build/agent-runs/never-made"
        self.assertIsNone(
            run_hook(
                self.payload(
                    f"cat {done}/notes", launcher_output(done) + launcher_output(ghost)
                )
            )
        )

    def test_unrelated_commands_stay_silent(self):
        self.assertIsNone(run_hook(self.payload("git status", "On branch main\n")))
        self.assertIsNone(
            run_hook(
                self.payload(
                    "python3 scripts/agent-build/agent-build.py status build/agent-runs/x",
                    "{}\n",
                )
            )
        )

    def test_failed_call_reads_the_error_text(self):
        # PostToolUseFailure: a chained command exited non-zero after start.
        run = make_run(self.root, "20261126T100000Z-demo-aaaa")
        payload = {
            "hook_event_name": "PostToolUseFailure",
            "tool_name": "Bash",
            "cwd": str(self.root),
            "tool_input": {"command": START + " | head -1; false"},
            "error": "Exit code 1\n" + launcher_output(run),
        }
        got = run_hook(payload)
        self.assertEqual(got["hookEventName"], "PostToolUseFailure")
        self.assertIn(f"agent-build.py wait {run}", got["additionalContext"])

    def test_a_mention_of_start_is_not_a_start(self):
        for command in (
            "sed -i 's/after agent-build.py start,/x/' notes.md",
            'grep -n "agent-build.py start" docs/dev/agent-builds.md',
        ):
            with self.subTest(command=command):
                self.assertIsNone(run_hook(self.payload(command, "")))

    def test_bad_input_never_fails_the_hook(self):
        for raw in ("", "not json", json.dumps({"tool_input": None})):
            with self.subTest(raw=raw):
                out = subprocess.run(
                    [sys.executable, str(HOOK)],
                    input=raw,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual((out.returncode, out.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
