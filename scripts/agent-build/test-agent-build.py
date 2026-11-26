#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Integration checks with a temporary Makefile; no Yocto build is invoked."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

LAUNCHER = Path(__file__).with_name("agent-build.py").resolve()
FIXTURES = Path(__file__).with_name("fixtures")
# A socket of this process's own: the default one carries real builds.
SOCKET = f"agent-build-selftest-{os.getpid()}"
os.environ["AGENT_BUILD_TMUX_SOCKET"] = SOCKET
_spec = importlib.util.spec_from_file_location("agent_build", LAUNCHER)
assert _spec is not None and _spec.loader is not None
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)
assert ab.SOCKET == SOCKET != "edge-builds"


def fake_run(tmp, **files):
    run = Path(tmp)
    run.mkdir(parents=True, exist_ok=True)
    (run / "run.json").write_text(
        json.dumps(
            {
                "session": "no-such-session",
                "board": "rzv2l",
                "command": ["make", "dev", "BOARD=rzv2l"],
            }
        )
    )
    for name, body in files.items():
        (run / name.replace("_", ".")).write_text(body)
    return run


def transport(sent, rows="%1 0"):
    """A tmux stand-in: list-panes answers "<pane id> <pane_dead>" rows, send-keys is recorded."""

    def tmux(*args, **_):
        if args[0] == "send-keys":
            sent.append(args)
        return rows

    return tmux


def fixture(name):
    # Bytes: the carriage returns of the terminal capture are part of the data.
    return (FIXTURES / name).read_bytes().decode()


class StateTest(unittest.TestCase):
    """run_state, progress, the log summary and wait without tmux or a build."""

    def setUp(self):
        # wait() prints its JSON; keep it out of the test report.
        self._quiet = contextlib.redirect_stdout(io.StringIO())
        self._quiet.__enter__()
        self.addCleanup(self._quiet.__exit__, None, None, None)

    def progress_of(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "terminal.log"
            log.write_bytes(text.encode())
            return ab.progress(log)

    def test_progress_from_a_coloured_log(self):
        log = (
            "\x1b[1mNOTE\x1b[0m: Executing Tasks\r"
            "Currently  2 running tasks (100 of 884)  11% |#   |\n"
            "0: zstd-1.5.7-r0 do_fetch - 1s (pid 11)\n"
            "Currently  3 running tasks (663 of 884)  75% |### |\r\n"
            "0: linux-renesas-6.12-r0 do_compile - 3m12s (pid 4242)\n"
            "1: \x1b]8;;file:///x\x1b\\python3-3.14.10-r0\x1b]8;;\x1b\\ do_install - 9s (pid 4300)\n"
            "2: rauc-1.15-r0 do_package_qa - 0.2s (pid 4301)\n"
            "NOTE: something else\n"
        )
        got = self.progress_of(log)
        self.assertEqual(
            (got["phase"], got["running"], got["task"], got["of"]),
            ("running", 3, 663, 884),
        )
        self.assertEqual(
            [t.split(" - ")[0] for t in got["tasks"]],
            [
                "linux-renesas-6.12-r0 do_compile",
                "python3-3.14.10-r0 do_install",
                "rauc-1.15-r0 do_package_qa",
            ],
        )

    def test_progress_follows_the_shutdown_blocks(self):
        # Captured from an interrupted build: after Ctrl-C BitBake prints
        # "Waiting for N running tasks to finish" and no "Currently" line.
        text = fixture("interrupt-start.txt")
        cut = text.index("Keyboard Interrupt")
        before = self.progress_of(text[:cut])
        self.assertEqual(
            (before["phase"], before["running"], before["task"], before["of"]),
            ("running", 9, 3003, 8770),
        )
        # Interrupted, no waiting block printed so far.
        self.assertEqual(self.progress_of(text[: cut + 40])["phase"], "shutting-down")
        got = self.progress_of(text)
        self.assertEqual(
            (got["phase"], got["running"], len(got["tasks"])), ("shutting-down", 10, 10)
        )
        self.assertNotIn("task", got)
        self.assertEqual(
            got["tasks"][0], "libunistring-1.4.2-r0 do_configure - 2m0s (pid 140402)"
        )
        self.assertIn("libassuan-3.0.2-r0 do_package_qa_setscene", got["tasks"][9])
        end = fixture("interrupt-end.txt")
        got = self.progress_of(end[: end.index("Summary:")])
        self.assertEqual(
            got,
            {
                "phase": "shutting-down",
                "running": 1,
                "tasks": [
                    "linux-edge-mainline-6.18.65+git-r0 do_compile - 12m3s (pid 143226)"
                ],
            },
        )

    def test_progress_skips_a_block_cut_short(self):
        got = self.progress_of(
            "Waiting for 2 running tasks to finish:\n"
            "0: a-1.0-r0 do_compile - 5s (pid 1)  12% |#    |\n"
            "1: b-1.0-r0 do_install - 1s (pid 2)\n"
            "Waiting for 2 running tasks to finish:\n"
            "WARNING: Exiting due to interrupt.\n"
        )
        self.assertEqual(
            got["tasks"],
            ["a-1.0-r0 do_compile - 5s (pid 1)", "b-1.0-r0 do_install - 1s (pid 2)"],
        )
        got = self.progress_of("Waiting for 0 running tasks to finish:\n")
        self.assertEqual(got, {"phase": "shutting-down", "running": 0, "tasks": []})

    def test_no_progress_line_gives_no_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(
                ab.progress(fake_run(tmp, terminal_log="make: x\n") / "terminal.log")
            )
            self.assertIsNone(ab.progress(Path(tmp) / "no-such.log"))

    def test_summary_kinds_from_captured_logs(self):
        def summary(name, code, interrupted=False):
            return ab.summarise_lines(ab.clean_lines(fixture(name)), code, interrupted)

        got = summary("task-failure.txt", 2)
        self.assertEqual(got["kind"], "task-failure")
        self.assertTrue(got["tasks_summary"].endswith("and 1 failed."))
        self.assertEqual(len(got["failed_tasks"]), 1)
        self.assertTrue(
            got["failed_tasks"][0]["task"].endswith("linux-qcom_6.18.bb:do_patch")
        )
        self.assertTrue(
            got["failed_tasks"][0]["log"].endswith("/temp/log.do_patch.3656035")
        )
        self.assertEqual(got["make_error"], "make: *** [Makefile:159: bundle] Error 1")
        # The next two failed although the Tasks Summary says "all succeeded".
        got = summary("disk-space.txt", 2)
        self.assertEqual((got["kind"], got["failed_tasks"]), ("disk-space", []))
        self.assertTrue(got["tasks_summary"].endswith("all succeeded."))
        self.assertIn("disk space monitor", got["errors"][0])
        got = summary("gate-failure.txt", 2)
        self.assertEqual(got["kind"], "gate-failure")
        self.assertTrue(got["tasks_summary"].endswith("all succeeded."))
        self.assertEqual(
            got["errors"], ["[khc-gate] ERROR: kernel-hardening-checker not on PATH"]
        )
        got = summary("interrupt-end.txt", -2, True)
        self.assertEqual((got["kind"], got["tasks_summary"]), ("interrupted", None))
        self.assertEqual(
            got["make_error"], "make: *** [Makefile:159: bundle] Interrupt"
        )
        # An interrupt the supervisor did not see is still read from the log.
        self.assertEqual(summary("interrupt-end.txt", 2)["kind"], "interrupted")
        self.assertEqual(summary("gate-failure.txt", 0)["kind"], "ok")
        self.assertEqual(
            ab.summarise_lines(["nothing recognisable"], 1)["kind"], "unknown"
        )
        # A log cut before BitBake's closing summary still names the task.
        got = ab.summarise_lines(
            ["ERROR: Task (/x/a_1.0.bb:do_compile) failed with exit code '1'"], 1
        )
        self.assertEqual(
            (got["kind"], got["failed_tasks"]),
            ("task-failure", [{"task": "/x/a_1.0.bb:do_compile", "log": None}]),
        )

    def test_summary_is_derived_for_a_result_without_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(
                tmp, result_json=json.dumps({"finished": "t", "exit_code": 2})
            )
            (run / "terminal.log").write_bytes(fixture("disk-space.txt").encode())
            got = ab.status_of(run)
            self.assertEqual((got["state"], got["kind"]), ("failed", "disk-space"))

    def test_source_tree_covers_untracked_files_and_leaves_the_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")} | {
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@example.invalid",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@example.invalid",
            }

            def git(*args):
                return subprocess.run(
                    ["git", "-C", tmp, *args],
                    check=True,
                    env=env,
                    capture_output=True,
                    text=True,
                ).stdout.strip()

            git("init", "-q")
            (root / ".gitignore").write_text("ignored.txt\n")
            (root / "tracked.txt").write_text("one\n")
            git("add", "-A")
            git("commit", "-q", "-m", "base")
            (root / "staged.txt").write_text("staged\n")
            git("add", "staged.txt")
            index = (root / ".git/index").read_bytes()
            staged, _ = ab.source_tree(root)
            self.assertRegex(staged, r"^[0-9a-f]{40,64}$")
            self.assertNotEqual(staged, git("rev-parse", "HEAD^{tree}"))
            (root / "ignored.txt").write_text("host-local\n")
            self.assertEqual(ab.source_tree(root)[0], staged)
            (root / "untracked.txt").write_text("new recipe\n")
            (root / "tracked.txt").write_text("two\n")
            tree, patch = ab.source_tree(root)
            self.assertNotEqual(tree, staged)
            self.assertIn(b"untracked.txt", patch)
            self.assertIn(b"+two", patch)
            self.assertNotIn(b"ignored.txt", patch)
            # Neither the index nor what is staged in it has moved.
            self.assertEqual((root / ".git/index").read_bytes(), index)
            self.assertEqual(git("diff", "--cached", "--name-only"), "staged.txt")
            # Past the second in which tracked.txt changed without changing size:
            # git then relies on the index timestamp to notice the change.
            time.sleep(1.1)
            run = root / "run"
            run.mkdir()
            state = ab.git_state(root, run)
            self.assertEqual(
                (state["tree"], state["tree_dirty"], state["patch"]),
                (tree, True, "source.patch"),
            )
            self.assertEqual(
                hashlib.sha256((run / "source.patch").read_bytes()).hexdigest(),
                state["patch_sha256"],
            )
            self.assertIn("?? untracked.txt", state["dirty"])
            self.assertEqual(state["head_tree"], git("rev-parse", "HEAD^{tree}"))
            # Outside a repository there is no identity to record.
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ab.git_state(Path(tmp))["tree"], None)

    def test_artifacts_and_disk_space(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "build/deploy").mkdir(parents=True)
            (root / "build/deploy/a.raucb").write_bytes(b"bundle")
            (root / "build/deploy/latest.raucb").symlink_to("a.raucb")
            got = ab.hash_artifacts(root, ["build/deploy/*.raucb", "build/none/*"])
            self.assertEqual(
                [e.get("path") for e in got],
                ["build/deploy/a.raucb", "build/deploy/latest.raucb", None],
            )
            self.assertEqual(got[0]["sha256"], hashlib.sha256(b"bundle").hexdigest())
            self.assertEqual(
                (got[1]["link_target"], got[2]["missing"]), ("a.raucb", True)
            )
            (root / "kas").mkdir()
            (root / "kas/local.yml").write_text(
                f'local_conf_header:\n  x: |\n    DL_DIR = "{tmp}/dl"\n'
                '    SSTATE_DIR ?= "${TOPDIR}/sstate"\n'
            )
            disks = ab.disk_state(root, root / "build/rzv2l")
            self.assertEqual([d["name"] for d in disks], ["build_dir", "dl_dir"])
            self.assertGreater(disks[0]["total_bytes"], 0)

    def test_list_is_newest_first_and_stop_refuses_a_finished_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "build/agent-runs"
            old = fake_run(
                runs / "20260101T000000Z-old-aaaaaaaa",
                started_json=json.dumps({"started": "2026-01-01T00:00:01+00:00"}),
                result_json=json.dumps(
                    {
                        "finished": "2026-01-01T01:02:04+00:00",
                        "exit_code": 2,
                        "kind": "task-failure",
                    }
                ),
            )
            fake_run(
                runs / "20260102T000000Z-new-bbbbbbbb",
                started_json=json.dumps({"started": "2026-01-02T00:00:00+00:00"}),
                result_json=json.dumps(
                    {
                        "finished": "t",
                        "exit_code": 0,
                        "duration_seconds": 61.0,
                        "kind": "ok",
                    }
                ),
            )
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                ab.list_runs(tmp, 0, True)
            rows = json.loads(out.getvalue())
            self.assertEqual(
                [
                    (r["run"][-8:], r["state"], r["kind"], r["duration_seconds"])
                    for r in rows
                ],
                [
                    ("bbbbbbbb", "succeeded", "ok", 61.0),
                    ("aaaaaaaa", "failed", "task-failure", 3723.0),
                ],
            )
            self.assertEqual(
                (rows[0]["board"], rows[0]["target"]), ("rzv2l", "dev BOARD=rzv2l")
            )
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                ab.list_runs(tmp, 1, False)
            table = out.getvalue().splitlines()
            self.assertEqual(len(table), 2)
            self.assertIn("2026-01-02 00:00:00Z", table[1])
            self.assertIn("1m01s", table[1])
            with self.assertRaisesRegex(RuntimeError, "failed, not running"):
                ab.stop(old, "no longer needed", "tester")
            self.assertFalse((old / "stop-request.json").exists())

    def test_stop_sends_one_graceful_interrupt_and_refuses_another(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            run = fake_run(tmp, started_json="{}")
            sent = []
            with mock.patch.object(ab, "tmux", transport(sent)):
                ab.stop(run, "too slow", "tester")
                # A record without a pane id: the session's only pane.
                self.assertEqual(sent, [("send-keys", "-t", "%1", "C-c")])
                # BitBake owns what follows; a further Ctrl-C is the operator's.
                with self.assertRaisesRegex(RuntimeError, "already"):
                    ab.stop(run, "still too slow", "tester")
                request = json.loads((run / "stop-request.json").read_text())
                self.assertEqual(ab.status_of(run)["stop"], request)
            self.assertEqual(len(sent), 1)
            self.assertEqual([i["reason"] for i in request["interrupts"]], ["too slow"])

    def test_stop_refuses_after_a_ctrl_c_the_supervisor_saw(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            # Written by the supervisor on the first Ctrl-C typed in the pane.
            run = fake_run(tmp, started_json="{}")
            (run / "interrupt-seen").write_text("t\n")
            sent = []
            with (
                mock.patch.object(ab, "tmux", transport(sent)),
                self.assertRaisesRegex(RuntimeError, "already"),
            ):
                ab.stop(run, "too slow", "tester")
            self.assertEqual((sent, (run / "stop-request.json").exists()), ([], False))

    def test_stop_targets_the_recorded_pane(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            run = fake_run(tmp, started_json="{}")
            meta = json.loads((run / "run.json").read_text()) | {"pane": "%7"}
            (run / "run.json").write_text(json.dumps(meta))
            sent = []
            # Another live pane in the session (a split shell) is never the target.
            with mock.patch.object(ab, "tmux", transport(sent, "%3 0\n%7 0")):
                ab.stop(run, "too slow", "tester")
            self.assertEqual(sent, [("send-keys", "-t", "%7", "C-c")])

    def test_stop_refuses_an_ambiguous_record_without_a_pane_id(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            run = fake_run(tmp, started_json="{}")
            sent = []
            with (
                mock.patch.object(ab, "tmux", transport(sent, "%1 0\n%2 0")),
                self.assertRaisesRegex(RuntimeError, "build pane"),
            ):
                ab.stop(run, "too slow", "tester")
            self.assertEqual((sent, (run / "stop-request.json").exists()), ([], False))

    def test_missing_pane_without_result_is_never_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")
            self.assertEqual(ab.status_of(run), {"state": "unknown/interrupted"})
            self.assertEqual(ab.wait(run, timeout=5, interval=0.01), 2)

    def test_dead_build_pane_is_not_hidden_by_a_live_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")
            meta = json.loads((run / "run.json").read_text()) | {"pane": "%7"}
            (run / "run.json").write_text(json.dumps(meta))
            for rows in ("%7 1\n%3 0", "%3 0"):
                with (
                    self.subTest(rows=rows),
                    mock.patch.object(ab, "tmux", transport([], rows)),
                ):
                    self.assertEqual(
                        ab.status_of(run), {"state": "unknown/interrupted"}
                    )
                    self.assertEqual(ab.wait(run, timeout=5, interval=0.01), 2)
            with mock.patch.object(ab, "tmux", transport([], "%3 0\n%7 0")):
                self.assertEqual(ab.status_of(run)["state"], "running")

    def test_result_written_as_the_pane_dies_is_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")

            def pane_gone(*_, **__):
                (run / "result.json").write_text(
                    json.dumps({"finished": "t", "exit_code": 0})
                )
                raise subprocess.CalledProcessError(1, "tmux")

            with mock.patch.object(ab, "tmux", pane_gone):
                self.assertEqual(ab.status_of(run)["state"], "succeeded")

    def test_missing_run_json_is_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ab.status_of(Path(tmp))["state"], "unknown/interrupted")
            self.assertEqual(ab.wait(Path(tmp), timeout=0), 2)

    def test_wait_exit_codes(self):
        cases = [
            ({"exit_code": 0}, 0),
            ({"exit_code": 2}, 1),
            ({"exit_code": -2}, 2),
            ({"exit_code": 2, "interrupted": True}, 2),
            ({"exit_code": 0, "interrupted": True}, 0),
        ]
        for result, code in cases:
            with self.subTest(result=result), tempfile.TemporaryDirectory() as tmp:
                run = fake_run(tmp, result_json=json.dumps({"finished": "t", **result}))
                self.assertEqual(ab.wait(run, timeout=0), code)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ab.wait(fake_run(tmp, startup_error="busy"), timeout=0), 2)

    def test_wait_times_out_while_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")
            with mock.patch.object(ab, "tmux", transport([])):
                started = time.monotonic()
                self.assertEqual(ab.wait(run, timeout=0.3, interval=0.05), 3)
                self.assertLess(time.monotonic() - started, 2)


class LauncherTest(unittest.TestCase):
    def test_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="agent build ") as tmp:
            root = Path(tmp)
            (root / "Makefile").write_text(
                "ok:\n\t@printf 'FIRST OUTPUT\\n'\n"
                '\t@test -t 1\n\t@test "$(FEATURE)" = 1\n'
                "\t@printf artifact > out.bin\n"
                "\t@printf 'LAST OUTPUT\\n'\n"
                "fail:\n\t@exit 7\n"
                "slow:\n\t@sleep 6\n\t@echo SURVIVED\n"
                "hold:\n\t@sleep 30\n"
                # The shell make would signal again ignores SIGINT; its child
                # gets one per Ctrl-C from the terminal and ends on the second.
                "stubborn:\n\t@trap '' INT; python3 stubborn.py\n"
                "dev:\n\t@true\n"
            )
            (root / "stubborn.py").write_text(
                "import signal, sys, time\n"
                "seen = []\n"
                "def interrupt(*_):\n"
                "    seen.append(1)\n"
                "    print('INTERRUPT', len(seen), flush=True)\n"
                "    if len(seen) >= 2:\n"
                "        sys.exit(3)\n"
                "signal.signal(signal.SIGINT, interrupt)\n"
                "while True:\n"
                "    time.sleep(0.1)\n"
            )
            env = dict(os.environ)
            for key in ("KAS_BUILD_DIR", "KAS_WORK_DIR", "BOARD"):
                env.pop(key, None)
            # Long enough that a finished session is still there to prune.
            env["AGENT_BUILD_LINGER"] = "120"
            sessions = []

            def tmux(*args):
                return subprocess.run(
                    ["tmux", "-L", SOCKET, *args],
                    capture_output=True,
                    text=True,
                    check=False,
                )

            def tool(*args):
                return subprocess.run(
                    [sys.executable, str(LAUNCHER), *args],
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )

            def start(topic, *make_args, options=()):
                return tool(
                    "start", "--worktree", str(root), *options, topic, "--", *make_args
                )

            def launch(target, *extra, success=True, options=()):
                result = start(target, target, *extra, options=options)
                runs = sorted(
                    (root / "build/agent-runs").iterdir(),
                    key=lambda p: p.stat().st_mtime_ns,
                )
                run = runs[-1]
                sessions.append(json.loads((run / "run.json").read_text())["session"])
                self.assertEqual(result.returncode == 0, success, result.stderr)
                return run

            def finish(run):
                deadline = time.monotonic() + 20
                while not (run / "result.json").exists():
                    self.assertLess(time.monotonic(), deadline, str(run))
                    time.sleep(0.05)
                return json.loads((run / "result.json").read_text())

            def started(run):
                deadline = time.monotonic() + 5
                while not (run / "started.json").exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                time.sleep(0.5)

            def state(run):
                return json.loads(tool("status", str(run)).stdout)["state"]

            def wait(run, timeout=10):
                result = tool("wait", "--timeout", str(timeout), str(run))
                return result.returncode, json.loads(result.stdout)

            def has_session(name):
                return tmux("has-session", "-t", "=" + name).returncode == 0

            fake: subprocess.Popen | None = None
            try:
                for bad in (("-C", "/tmp", "ok"), ("ok", "KAS_BUILD_DIR=/tmp/x")):
                    refused = start("refused", *bad)
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn("VAR=value", refused.stderr)
                for options in (
                    ("--artifact", "/etc/hostname"),
                    ("--artifact", "../x"),
                    ("--parent", "no-such-run"),
                ):
                    refused = start("refused", "ok", options=options)
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn(options[0], refused.stderr)
                # One build per host: a bitbake target is refused while a
                # bitbake process runs, whatever its board or build directory.
                (root / "fake/bin").mkdir(parents=True)
                # No exec: the process must keep its .../bin/bitbake command line.
                (root / "fake/bin/bitbake").write_text("#!/bin/sh\nsleep 30\n")
                (root / "fake/bin/bitbake").chmod(0o755)
                fake = subprocess.Popen([str(root / "fake/bin/bitbake")])
                time.sleep(0.2)
                refused = start("busy", "dev")
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("one build at a time", refused.stderr)
                fake.terminate()
                fake.wait()
                fake = None
                # This first session lingers, so the tmux server persists with
                # an earlier client's settings while the next launch changes them.
                first = run = launch("fail", "FEATURE=0")
                result = finish(run)
                self.assertEqual(
                    result["exit_code"], 2
                )  # make's status, not the recipe shell's 7
                # Written with the result, from a log the pane feeds asynchronously.
                self.assertEqual(result["kind"], "gate-failure")
                self.assertRegex(result["make_error"], r"^make: \*\*\* .*Error 7$")
                self.assertGreaterEqual(result["duration_seconds"], 0)
                self.assertEqual(state(run), "failed")
                self.assertEqual(wait(run)[0], 1)
                meta = json.loads((run / "run.json").read_text())
                self.assertEqual(meta["board"], "rzv2l")
                self.assertRegex(meta["pane"], r"^%\d+$")
                self.assertEqual(meta["build_dir"], str(root / "build/rzv2l"))
                self.assertIn("BOARD=rzv2l", meta["command"])
                self.assertIn("dirty", meta["source"])
                self.assertEqual((meta["parent"], meta["tmux_socket"]), (None, SOCKET))
                disk = json.loads((run / "started.json").read_text())["disk"]
                self.assertEqual(disk[0]["name"], "build_dir")
                # The server's command line is this launcher, not a common utility.
                pid = tmux("display-message", "-p", "#{pid}").stdout.strip()
                cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().decode()
                self.assertNotIn("sleep", cmdline)
                run = launch(
                    "ok",
                    "FEATURE=1",
                    "BOARD=raspberrypi5",
                    options=(
                        "--parent",
                        first.name,
                        "--artifact",
                        "out.bin",
                        "--artifact",
                        "none*",
                    ),
                )
                code, out = wait(
                    run
                )  # blocks until the run ends, no polling by the caller
                self.assertEqual(
                    (code, out["state"], out["kind"]), (0, "succeeded", "ok")
                )
                result = finish(run)
                self.assertEqual(result["exit_code"], 0)
                self.assertEqual(
                    [(a["pattern"], a.get("sha256")) for a in result["artifacts"]],
                    [
                        ("out.bin", hashlib.sha256(b"artifact").hexdigest()),
                        ("none*", None),
                    ],
                )
                self.assertEqual(state(run), "succeeded")
                meta = json.loads((run / "run.json").read_text())
                self.assertEqual(meta["build_dir"], str(root / "build/raspberrypi5"))
                self.assertEqual(meta["parent"], first.name)
                deadline = time.monotonic() + 5
                while "LAST OUTPUT" not in (run / "terminal.log").read_text():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                self.assertIn("FIRST OUTPUT", (run / "terminal.log").read_text())
                run = launch("slow")
                self.assertEqual(state(run), "running")
                launch(
                    "ok", "FEATURE=1", success=False
                )  # same build directory is locked
                self.assertEqual(
                    finish(run)["exit_code"], 0
                )  # survives launcher process exit
                # A lingering finished session no longer holds the build directory.
                self.assertTrue(has_session(sessions[-2]))
                self.assertEqual(finish(launch("ok", "FEATURE=1"))["exit_code"], 0)
                # A session ends by itself after its linger period.
                run = launch("ok", "FEATURE=1", options=("--linger", "0.5"))
                finish(run)
                deadline = time.monotonic() + 5
                while has_session(sessions[-1]):
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.1)
                self.assertEqual(state(run), "succeeded")
                # Ctrl-C reaches make, not the supervisor: recorded, and reported
                # as an interruption rather than a build failure.
                run = launch("hold")
                started(run)
                tmux("send-keys", "-t", "=" + sessions[-1] + ":", "C-c")
                # make dies by SIGINT (-2), or exits 2 when it reaps the
                # interrupted child first; either is an interruption.
                result = finish(run)
                self.assertIn(result["exit_code"], (-2, 2))
                self.assertEqual(
                    (result["kind"], result["interrupted"]), ("interrupted", True)
                )
                self.assertNotIn("stop", result)
                self.assertEqual(state(run), "interrupted")
                # stop: the reason is recorded, and only that run's pane gets
                # the Ctrl-C, not a session whose name merely starts the same.
                bystander = launch("hold", "BOARD=other")
                run = launch("hold")
                neighbour = sessions[-1] + "0"
                sessions.append(neighbour)
                tmux(
                    "new-session",
                    "-d",
                    "-s",
                    neighbour,
                    sys.executable,
                    str(LAUNCHER),
                    "_hold",
                )
                started(run)
                self.assertNotEqual(tool("stop", str(run)).returncode, 0)  # no --reason
                stopped = tool(
                    "stop",
                    "--reason",
                    "selftest: wrong configuration",
                    "--by",
                    "tester",
                    str(run),
                )
                self.assertEqual(stopped.returncode, 0, stopped.stderr)
                result = finish(run)
                self.assertEqual(
                    (result["kind"], result["interrupted"]), ("interrupted", True)
                )
                self.assertEqual(
                    [(i["reason"], i["by"]) for i in result["stop"]["interrupts"]],
                    [("selftest: wrong configuration", "tester")],
                )
                self.assertEqual(state(run), "interrupted")
                self.assertNotEqual(
                    tool("stop", "--reason", "again", str(run)).returncode, 0
                )
                self.assertEqual(state(bystander), "running")
                self.assertTrue(has_session(neighbour))
                # A build that outlives the first Ctrl-C, as BitBake does while
                # its tasks finish: one stop, then further Ctrl-C is the operator's.
                run = launch("stubborn")
                started(run)
                pane = json.loads((run / "run.json").read_text())["pane"]
                self.assertEqual(
                    tool("stop", "--reason", "first", str(run)).returncode, 0
                )
                time.sleep(1)
                waiting = json.loads(tool("status", str(run)).stdout)
                self.assertEqual(
                    (waiting["state"], len(waiting["stop"]["interrupts"])),
                    ("running", 1),
                )
                self.assertTrue((run / "interrupt-seen").exists())
                self.assertNotEqual(
                    tool("stop", "--reason", "second", str(run)).returncode, 0
                )
                tmux("send-keys", "-t", pane, "C-c")
                result = finish(run)
                self.assertEqual(
                    [i["reason"] for i in result["stop"]["interrupts"]], ["first"]
                )
                self.assertEqual(
                    (result["kind"], state(run)), ("interrupted", "interrupted")
                )
                # A Ctrl-C typed in the pane first: stop would be BitBake's
                # second, so it is refused and sends nothing.
                run = launch("stubborn")
                started(run)
                pane = json.loads((run / "run.json").read_text())["pane"]
                tmux("send-keys", "-t", pane, "C-c")
                deadline = time.monotonic() + 10
                while not (run / "interrupt-seen").exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                typed = tool("stop", "--reason", "late", str(run))
                self.assertNotEqual(typed.returncode, 0)
                self.assertIn("already", typed.stderr)
                self.assertFalse((run / "stop-request.json").exists())
                tmux("send-keys", "-t", pane, "C-c")
                result = finish(run)
                self.assertEqual(
                    (result.get("interrupted"), "stop" in result), (True, False)
                )
                self.assertEqual(state(bystander), "running")
                listing = tool("list", "--worktree", str(root), "--json")
                rows = json.loads(listing.stdout)
                self.assertEqual(rows[0]["run"], max(r["run"] for r in rows))
                by_run = {r["run"]: r for r in rows}
                self.assertEqual(by_run[run.name]["state"], "interrupted")
                self.assertEqual(
                    (by_run[bystander.name]["state"], by_run[bystander.name]["board"]),
                    ("running", "other"),
                )
                self.assertIn(
                    first.name,
                    tool("list", "--worktree", str(root), "--limit", "0").stdout,
                )
                # prune closes finished runs' sessions only.
                self.assertTrue(has_session(sessions[0]))
                dry = json.loads(tool("prune", "--dry-run").stdout)
                self.assertTrue(has_session(sessions[0]))
                pruned = json.loads(tool("prune").stdout)
                self.assertEqual(dry["closed"], pruned["closed"])
                closed = {entry["session"] for entry in pruned["closed"]}
                self.assertIn(sessions[0], closed)
                self.assertFalse(has_session(sessions[0]))
                kept = {entry["session"]: entry["reason"] for entry in pruned["kept"]}
                self.assertIn("running", kept["build-" + bystander.name])
                self.assertEqual(kept[neighbour], "no run record found")
                self.assertEqual(state(bystander), "running")
                self.assertTrue(has_session(neighbour))
                self.assertEqual(
                    state(first), "failed"
                )  # the record outlives the session
                code, out = wait(bystander, timeout=1)
                self.assertEqual(
                    (code, out["state"], out.get("timeout")), (3, "running", True)
                )
                tmux("kill-session", "-t", "=build-" + bystander.name)
                self.assertEqual(state(bystander), "unknown/interrupted")
                # A vanished session without result.json is never a success.
                self.assertEqual(wait(bystander)[0], 2)
            finally:
                if fake is not None:
                    fake.kill()
                for session in sessions:
                    tmux("kill-session", "-t", "=" + session)
                # tmux leaves the socket of an exited server behind.
                (
                    Path(os.environ.get("TMUX_TMPDIR", "/tmp"))
                    / f"tmux-{os.getuid()}"
                    / SOCKET
                ).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
