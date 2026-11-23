#!/usr/bin/env python3
"""Integration checks with a temporary Makefile; no Yocto build is invoked."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

LAUNCHER = Path(__file__).with_name("agent-build.py").resolve()
SOCKET = "edge-builds"
_spec = importlib.util.spec_from_file_location("agent_build", LAUNCHER)
assert _spec is not None and _spec.loader is not None
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)


def fake_run(tmp, **files):
    run = Path(tmp)
    (run / "run.json").write_text(json.dumps({"session": "no-such-session"}))
    for name, body in files.items():
        (run / name.replace("_", ".")).write_text(body)
    return run


class StateTest(unittest.TestCase):
    """run_state, progress and wait without tmux or a build."""

    def test_progress_from_a_coloured_log(self):
        log = ("\x1b[1mNOTE\x1b[0m: Executing Tasks\r"
               "Currently  2 running tasks (100 of 884)  11% |#   |\n"
               "0: zstd-1.5.7-r0 do_fetch - 1s (pid 11)\n"
               "Currently  3 running tasks (663 of 884)  75% |### |\r\n"
               "0: linux-renesas-6.12-r0 do_compile - 3m12s (pid 4242)\n"
               "1: \x1b]8;;file:///x\x1b\\python3-3.14.10-r0\x1b]8;;\x1b\\ do_install - 9s (pid 4300)\n"
               "2: rauc-1.15-r0 do_package_qa - 0.2s (pid 4301)\n"
               "NOTE: something else\n")
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, terminal_log=log)
            got = ab.progress(run / "terminal.log")
            self.assertEqual((got["running"], got["task"], got["of"]), (3, 663, 884))
            self.assertEqual([t.split(" - ")[0] for t in got["tasks"]],
                             ["linux-renesas-6.12-r0 do_compile",
                              "python3-3.14.10-r0 do_install",
                              "rauc-1.15-r0 do_package_qa"])

    def test_no_progress_line_gives_no_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(ab.progress(fake_run(tmp, terminal_log="make: x\n") / "terminal.log"))
            self.assertIsNone(ab.progress(Path(tmp) / "no-such.log"))

    def test_missing_pane_without_result_is_never_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")
            self.assertEqual(ab.status_of(run), {"state": "unknown/interrupted"})
            self.assertEqual(ab.wait(run, timeout=5, interval=0.01), 2)

    def test_result_written_as_the_pane_dies_is_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")

            def pane_gone(*_):
                (run / "result.json").write_text(json.dumps({"finished": "t", "exit_code": 0}))
                raise subprocess.CalledProcessError(1, "tmux")

            saved, ab.tmux = ab.tmux, pane_gone
            try:
                self.assertEqual(ab.status_of(run)["state"], "succeeded")
            finally:
                ab.tmux = saved

    def test_missing_run_json_is_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ab.status_of(Path(tmp))["state"], "unknown/interrupted")
            self.assertEqual(ab.wait(Path(tmp), timeout=0), 2)

    def test_wait_exit_codes(self):
        cases = [({"exit_code": 0}, 0), ({"exit_code": 2}, 1), ({"exit_code": -2}, 2)]
        for result, code in cases:
            with self.subTest(result=result), tempfile.TemporaryDirectory() as tmp:
                run = fake_run(tmp, result_json=json.dumps({"finished": "t", **result}))
                self.assertEqual(ab.wait(run, timeout=0), code)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ab.wait(fake_run(tmp, startup_error="busy"), timeout=0), 2)

    def test_wait_times_out_while_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(tmp, started_json="{}")
            saved, ab.tmux = ab.tmux, lambda *_: "0"
            try:
                started = time.monotonic()
                self.assertEqual(ab.wait(run, timeout=0.3, interval=0.05), 3)
                self.assertLess(time.monotonic() - started, 2)
            finally:
                ab.tmux = saved


class LauncherTest(unittest.TestCase):
    def test_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="agent build ") as tmp:
            root = Path(tmp)
            (root / "Makefile").write_text(
                "ok:\n\t@printf 'FIRST OUTPUT\\n'\n"
                "\t@test -t 1\n\t@test \"$(FEATURE)\" = 1\n"
                "\t@printf 'LAST OUTPUT\\n'\n"
                "fail:\n\t@exit 7\n"
                "slow:\n\t@sleep 3\n\t@echo SURVIVED\n"
                "hold:\n\t@sleep 30\n"
                "dev:\n\t@true\n")
            env = dict(os.environ)
            for key in ("KAS_BUILD_DIR", "KAS_WORK_DIR", "BOARD"):
                env.pop(key, None)
            sessions = []

            def start(topic, *make_args):
                return subprocess.run([sys.executable, str(LAUNCHER), "start", "--worktree",
                                       str(root), topic, "--", *make_args], env=env,
                                      text=True, capture_output=True)

            def launch(target, *extra, success=True):
                result = start(target, target, *extra)
                runs = sorted((root / "build/agent-runs").iterdir(), key=lambda p: p.stat().st_mtime_ns)
                run = runs[-1]
                sessions.append(json.loads((run / "run.json").read_text())["session"])
                self.assertEqual(result.returncode == 0, success, result.stderr)
                return run

            def finish(run):
                deadline = time.monotonic() + 10
                while not (run / "result.json").exists():
                    self.assertLess(time.monotonic(), deadline, str(run))
                    time.sleep(0.05)
                return json.loads((run / "result.json").read_text())["exit_code"]

            def state(run):
                result = subprocess.check_output([sys.executable, str(LAUNCHER), "status", str(run)], text=True)
                return json.loads(result)["state"]

            def wait(run, timeout=10):
                result = subprocess.run([sys.executable, str(LAUNCHER), "wait", "--timeout",
                                         str(timeout), str(run)], text=True, capture_output=True)
                return result.returncode, json.loads(result.stdout)

            fake = None
            try:
                for bad in (("-C", "/tmp", "ok"), ("ok", "KAS_BUILD_DIR=/tmp/x")):
                    refused = start("refused", *bad)
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn("VAR=value", refused.stderr)
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
                # Keep this first pane so the tmux server persists with an
                # earlier client's settings while the next launch changes them.
                run = launch("fail", "FEATURE=0")
                self.assertEqual(finish(run), 2)  # make's status, not the recipe shell's 7
                self.assertEqual(state(run), "failed")
                self.assertEqual(wait(run)[0], 1)
                meta = json.loads((run / "run.json").read_text())
                self.assertEqual(meta["board"], "rzv2l")
                self.assertEqual(meta["build_dir"], str(root / "build/rzv2l"))
                self.assertIn("BOARD=rzv2l", meta["command"])
                self.assertIn("dirty", meta["source"])
                run = launch("ok", "FEATURE=1", "BOARD=raspberrypi5")
                code, out = wait(run)  # blocks until the run ends, no polling by the caller
                self.assertEqual((code, out["state"]), (0, "succeeded"))
                self.assertEqual(finish(run), 0)
                self.assertEqual(state(run), "succeeded")
                meta = json.loads((run / "run.json").read_text())
                self.assertEqual(meta["build_dir"], str(root / "build/raspberrypi5"))
                deadline = time.monotonic() + 5
                while "LAST OUTPUT" not in (run / "terminal.log").read_text():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                self.assertIn("FIRST OUTPUT", (run / "terminal.log").read_text())
                run = launch("slow")
                self.assertEqual(state(run), "running")
                launch("ok", "FEATURE=1", success=False)  # same build directory is locked
                self.assertEqual(finish(run), 0)  # survives launcher process exit
                # Ctrl-C reaches make, not the supervisor: recorded, and reported
                # as an interruption rather than a build failure.
                run = launch("hold")
                deadline = time.monotonic() + 5
                while not (run / "started.json").exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                time.sleep(0.5)
                subprocess.run(["tmux", "-L", SOCKET, "send-keys", "-t", sessions[-1], "C-c"], check=True)
                self.assertEqual(finish(run), -2)
                self.assertEqual(state(run), "interrupted")
                run = launch("hold")
                code, out = wait(run, timeout=1)
                self.assertEqual((code, out["state"], out.get("timeout")), (3, "running", True))
                subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", sessions[-1]], check=True)
                self.assertEqual(state(run), "unknown/interrupted")
                # A vanished session without result.json is never a success.
                self.assertEqual(wait(run)[0], 2)
            finally:
                if fake:
                    fake.kill()
                for session in sessions:
                    subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", session], capture_output=True)


if __name__ == "__main__":
    unittest.main()
