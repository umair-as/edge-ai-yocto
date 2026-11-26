#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Run make in a logged tmux pane, independently of an agent's tool call.

Usage:
  agent-build.py start [--worktree PATH] [--parent RUN] [--artifact GLOB]...
                       [--linger SECONDS] <topic> -- <target>... [VAR=value]...
  agent-build.py status <run-dir>
  agent-build.py wait [--timeout SECONDS] <run-dir>
  agent-build.py stop --reason TEXT [--by NAME] <run-dir>
  agent-build.py list [--worktree PATH] [--limit N] [--json]
  agent-build.py prune [--worktree PATH] [--dry-run]

Each run gets build/agent-runs/<run-id>/ with run.json (command, board, build
directory, source commit and tree id, parent run), source.patch (a dirty
tree's difference from HEAD), started.json (start time, free disk space),
result.json (make's exit code, failure kind, log summary, artifact hashes),
stop-request.json (who stopped it and why) and terminal.log. Launcher
timestamps are UTC. See docs/dev/agent-builds.md.

status prints the run's state as JSON, with BitBake task progress and phase
(running or shutting-down) while it runs. wait blocks until the run ends or
the timeout passes, prints the same JSON and exits 0 succeeded, 1 failed,
2 interrupted, unknown or startup failure, 3 still running at the timeout. A
run whose pane is gone without a result.json is never a success.

stop records the reason and sends one Ctrl-C to that run's build pane; BitBake
then finishes its running tasks before it exits. stop sends nothing once the
run has been interrupted (a stop, or a Ctrl-C typed in the pane): any further
Ctrl-C, which makes BitBake terminate its tasks, is the operator's. list prints
the runs of a checkout, newest first. A finished run's session closes itself
after the linger period (default 600 s); prune closes finished runs' sessions
at once and never touches a running one, nor a pane that ended without a result.

All of these use this launcher's tmux socket (edge-builds, or
AGENT_BUILD_TMUX_SOCKET); a plain `tmux` talks to another server and never
finds the session.
"""

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

SELF = Path(__file__).resolve()
SOCKET = os.environ.get("AGENT_BUILD_TMUX_SOCKET") or "edge-builds"
DEFAULT_BOARD = "rzv2l"  # the Makefile's BOARD default
# Makefile targets that end up running bitbake; keep in step with the Makefile
# and the parallel-build hook's MAKE_BUILD_TARGETS.
BUILD_TARGETS = {
    "base",
    "dev",
    "prod",
    "bundle",
    "parse",
    "layers",
    "shell",
    "ci",
    "kernel-config-export",
    "kernel-hardening-check",
    "kernel-hash",
    "bootchain-bundle",
    "bootloader-package",
}
RUNNING = r"bin/(bitbake|bitbake-server|kas|kas-container)( |$)"
# Seconds a finished run's session stays open for reading before it closes.
LINGER = 600
# A larger source.patch is hashed but not stored.
PATCH_LIMIT = 4 * 1024 * 1024
ARTIFACT_LIMIT = 20
# Session option naming the run directory: the tmux server is shared by every
# checkout, so prune cannot assume a session's run lives under its own root.
RUN_OPTION = "@agent_build_run"


def tmux(*args, socket=None):
    return subprocess.run(
        ["tmux", "-L", socket or SOCKET, *args],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()


def now():
    return dt.datetime.now(dt.UTC).isoformat()


def write_json(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wait_for(path, seconds=15):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"Timed out waiting for {path}; inspect the run before retrying"
            )
        time.sleep(0.05)


def running_builds():
    out = subprocess.run(
        ["pgrep", "-af", RUNNING], capture_output=True, text=True, check=False
    ).stdout
    # Shell wrappers that merely mention a path in their command string are not builds.
    return [line for line in out.splitlines() if not re.match(r"\d+ \S*sh -c ", line)]


def source_tree(root):
    """Tree id of the working tree: tracked and untracked files, minus ignored ones.

    Built in a temporary index, so the checkout's own index and staging are
    untouched; only blob and tree objects are added to the object store.
    """

    def git(*args, env=None):
        result = subprocess.run(
            ["git", "-C", str(root), *args], capture_output=True, env=env, check=False
        )
        return result.stdout if result.returncode == 0 else None

    index = git("rev-parse", "--git-path", "index")
    if index is None:
        return None, None
    with tempfile.TemporaryDirectory(prefix="agent-build-index-") as tmp:
        scratch = Path(tmp) / "index"
        real = root / index.decode().strip()
        if real.is_file():
            # The copy carries the stat cache, so unchanged files are not rehashed,
            # and the timestamp git needs to recheck files changed in its second.
            shutil.copy2(real, scratch)
        env = os.environ | {"GIT_INDEX_FILE": str(scratch)}
        if git("add", "-A", env=env) is None:
            return None, None
        tree = git("write-tree", env=env)
    if tree is None:
        return None, None
    tree = tree.decode().strip()
    head = git("rev-parse", "--verify", "--quiet", "HEAD^{tree}")
    if head is None:
        return tree, None
    return tree, git("diff", "--binary", head.decode().strip(), tree)


def git_state(root, run=None):
    def git(*args):
        result = subprocess.run(
            ["git", "-C", str(root), *args], capture_output=True, text=True, check=False
        )
        return result.stdout.strip() if result.returncode == 0 else None

    # --no-optional-locks: status must not rewrite the index of a checkout
    # another process may be using.
    status = git("--no-optional-locks", "status", "--porcelain")
    state = {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "dirty": status.splitlines() if status else [],
    }
    # The commit does not identify a dirty tree, and `git diff` omits untracked
    # files; the tree id covers both.
    tree, patch = source_tree(root)
    state["tree"] = tree
    state["head_tree"] = git("rev-parse", "--verify", "--quiet", "HEAD^{tree}")
    state["tree_dirty"] = None if tree is None else tree != state["head_tree"]
    if patch:
        state["patch_sha256"] = hashlib.sha256(patch).hexdigest()
        state["patch_bytes"] = len(patch)
        if run is not None and len(patch) <= PATCH_LIMIT:
            (run / "source.patch").write_bytes(patch)
            state["patch"] = "source.patch"
    # Ignored, so outside the tree id; it holds host paths, hence the hash only.
    local = root / "kas" / "local.yml"
    if local.is_file():
        state["local_yml_sha256"] = sha256_file(local)
    return state


CACHE_DIR = re.compile(
    r'^\s*(DL_DIR|SSTATE_DIR|TMPDIR)\s*[?:]?=\s*"(/[^"$]*)"', re.MULTILINE
)


def disk_state(root, build):
    """Free space of the build directory and of the cache paths kas/local.yml names."""
    paths = {"build_dir": str(build)}
    try:
        paths |= {
            name.lower(): path
            for name, path in CACHE_DIR.findall(
                (root / "kas" / "local.yml").read_text()
            )
        }
    except OSError:
        pass
    disks = []
    for name, path in paths.items():
        probe = Path(path)
        while not probe.exists() and probe != probe.parent:
            probe = probe.parent
        try:
            usage = shutil.disk_usage(probe)
        except OSError:
            continue
        disks.append(
            {
                "name": name,
                "path": path,
                "free_bytes": usage.free,
                "total_bytes": usage.total,
                "used_percent": round(100 * (1 - usage.free / usage.total), 1)
                if usage.total
                else None,
            }
        )
    return disks


def hash_artifacts(root, patterns):
    """sha256 of the files the run's --artifact globs match, relative to the checkout."""
    found = []
    for pattern in patterns:
        files = [p for p in sorted(root.glob(pattern)) if p.is_file()]
        if not files:
            found.append({"pattern": pattern, "missing": True})
        for path in files[:ARTIFACT_LIMIT]:
            stat = path.stat()
            entry = {
                "pattern": pattern,
                "path": str(path.relative_to(root)),
                "bytes": stat.st_size,
                "modified": dt.datetime.fromtimestamp(
                    stat.st_mtime, dt.UTC
                ).isoformat(),
                "sha256": sha256_file(path),
            }
            if path.is_symlink():
                entry["link_target"] = path.resolve().name
            found.append(entry)
        if len(files) > ARTIFACT_LIMIT:
            found.append(
                {"pattern": pattern, "not_hashed": len(files) - ARTIFACT_LIMIT}
            )
    return found


def log_reached(log, marker, seconds=3.0):
    """Wait until the asynchronous pane capture has written the marker to the log."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            with open(log, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                fh.seek(max(0, fh.tell() - 4096))
                if marker.encode() in fh.read():
                    return True
        except OSError:
            pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def runner(run):
    meta = json.loads((run / "run.json").read_text())
    build = Path(meta["build_dir"])
    root = Path(meta["worktree"])
    build.mkdir(parents=True, exist_ok=True)
    with (build / ".agent-build.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            (run / "startup-error").write_text(
                "Another launcher build owns this build directory\n"
            )
            return 1
        (run / "ready").touch()
        try:
            wait_for(run / "start", 30)
        except RuntimeError as exc:
            (run / "startup-error").write_text(str(exc) + "\n")
            return 1
        # Preserve the pane's terminal settings, but never inherit stale build
        # settings from a previously started tmux server.
        env = meta["environment"] | {"TERM": os.environ.get("TERM", "screen")}
        write_json(
            run / "started.json",
            {"started": now(), "pid": os.getpid(), "disk": disk_state(root, build)},
        )
        began = time.monotonic()
        print("+ " + shlex.join(meta["command"]), flush=True)
        # Ctrl-C reaches make through the pane's foreground process group, and
        # this supervisor with it. The supervisor stays alive to record make's
        # status and notes the interrupt itself: make exits 2, not by signal,
        # when its interrupted child is reaped first (and bitbake always exits
        # cleanly on SIGINT), so the exit code alone cannot tell.
        interrupted = []

        def on_interrupt(*_):
            # First-hand record for stop: a Ctrl-C reached the build.
            if not interrupted:
                (run / "interrupt-seen").write_text(now() + "\n")
            interrupted.append(True)

        signal.signal(signal.SIGINT, on_interrupt)
        process = subprocess.Popen(
            meta["command"], cwd=meta["worktree"], env=env, pass_fds=(lock.fileno(),)
        )
        code = process.wait()
        result = {
            "finished": now(),
            "exit_code": code,
            "duration_seconds": round(time.monotonic() - began, 1),
        }
        if interrupted:
            result["interrupted"] = True
        stop = read_json(run / "stop-request.json")
        if stop:
            result["stop"] = stop
        marker = f"BUILD EXIT={code}"
        print("\n" + marker, flush=True)
        # The summary is an aid; make's exit code is recorded whatever it does.
        try:
            log_reached(run / "terminal.log", marker)
            result |= summarise(run / "terminal.log", code, bool(interrupted))
            if code == 0 and meta.get("artifacts"):
                result["artifacts"] = hash_artifacts(root, meta["artifacts"])
        except Exception as exc:  # noqa: BLE001 - any summary failure must not lose the exit code
            result["summary_error"] = f"{type(exc).__name__}: {exc}"
        write_json(run / "result.json", result)
    # The build-directory lock is released; only the pane stays, for reading.
    linger = meta.get("linger_seconds", LINGER)
    if linger > 0:
        print(
            f"Session closes in {linger:g} s (Ctrl-C closes it now); the log stays in {run}",
            flush=True,
        )
        signal.signal(signal.SIGINT, signal.default_int_handler)
        try:
            time.sleep(linger)
        except KeyboardInterrupt:
            pass
    # make's status is in result.json; a non-zero exit here would keep the pane.
    return 0


def runs_dir(root):
    return Path(root).resolve() / "build" / "agent-runs"


def start(args):
    root = Path(args.worktree).resolve()
    if not (root / "Makefile").is_file():
        raise ValueError(f"No Makefile in {root}")
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.topic):
        raise ValueError(
            "Topic must contain only letters, digits, underscores or hyphens"
        )
    command = args.make_args
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise ValueError("Supply a make target")
    for arg in command:
        if arg.startswith(("-", "KAS_BUILD_DIR=", "KAS_WORK_DIR=")):
            raise ValueError(
                "Use targets and VAR=value arguments only; "
                "the build directory follows BOARD"
            )
    for pattern in args.artifact:
        if Path(pattern).is_absolute() or ".." in Path(pattern).parts:
            raise ValueError(
                f"--artifact {pattern!r} must be a glob relative to the checkout"
            )
    if args.linger < 0:
        raise ValueError("--linger must not be negative")
    parent = None
    if args.parent:
        parent = Path(args.parent).name
        if not (runs_dir(root) / parent / "run.json").is_file():
            raise ValueError(f"--parent {parent}: no such run under {runs_dir(root)}")
    # The Makefile derives the build directory from BOARD and ignores an
    # inherited KAS_BUILD_DIR; resolve it the same way and record BOARD.
    boards = [a.split("=", 1)[1] for a in command if a.startswith("BOARD=")]
    board = boards[-1] if boards else os.environ.get("BOARD", DEFAULT_BOARD)
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", board):
        raise ValueError(f"Invalid BOARD {board!r}")
    if not boards:
        command = [*command, f"BOARD={board}"]
    if BUILD_TARGETS & set(command):
        busy = running_builds()
        if busy:
            raise RuntimeError(
                "A bitbake/kas build is already running on this host; one build "
                "at a time: " + "; ".join(line[:120] for line in busy[:3])
            )
    # Explicit, limited environment transfer. Do not persist credentials or a
    # wholesale environment dump. Host-local cache paths come from scripts/env.sh.
    names = {
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TMPDIR",
        "KAS_WORK_DIR",
        "KAS_REPO_REF_DIR",
    }
    env = {k: os.environ[k] for k in names if k in os.environ}
    env.setdefault("KAS_WORK_DIR", str(root / ".kas"))
    build = root / "build" / board
    run_id = (
        dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
        + "-"
        + args.topic
        + "-"
        + uuid.uuid4().hex[:8]
    )
    run = runs_dir(root) / run_id
    run.mkdir(parents=True, mode=0o700)
    session = "build-" + run_id
    # Launcher timestamps are UTC; kas and BitBake print local time in
    # terminal.log, so the host's offset is recorded beside them.
    meta = {
        "created": now(),
        "local_utc_offset": dt.datetime.now().astimezone().strftime("%z"),
        "worktree": str(root),
        "board": board,
        "build_dir": str(build),
        "source": git_state(root, run),
        "parent": parent,
        "artifacts": args.artifact,
        "linger_seconds": args.linger,
        "session": session,
        "tmux_socket": SOCKET,
        "command": ["make", *command],
        "environment": env,
    }
    write_json(run / "run.json", meta)
    # Start a waiting runner, configure capture, then release it. No send-keys
    # and no race between initial make output and installing pipe-pane.
    # history-limit only applies to panes created after it is set, so a
    # placeholder holds the session open while the options are applied. Both
    # are scoped to this session; global and user tmux settings are untouched.
    # A new tmux server takes its command line from this first client, so the
    # placeholder is this script, which no pattern aimed at a common utility
    # name matches.
    placeholder = tmux(
        "new-session",
        "-d",
        "-P",
        "-F",
        "#{pane_id}",
        "-s",
        session,
        sys.executable,
        str(SELF),
        "_hold",
    )
    try:
        tmux("set-option", "-t", "=" + session + ":", "mouse", "on")
        tmux("set-option", "-t", "=" + session + ":", "history-limit", "50000")
        tmux("set-option", "-t", "=" + session + ":", RUN_OPTION, str(run))
        pane = tmux(
            "new-window",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-t",
            "=" + session + ":",
            "-c",
            str(root),
            sys.executable,
            str(SELF),
            "_run",
            str(run),
        )
        tmux("kill-pane", "-t", placeholder)
        meta["pane"] = pane
        write_json(run / "run.json", meta)
        # A runner that dies without recording a result leaves its pane, and
        # whatever it printed, for inspection; one that finishes closes it.
        tmux("set-option", "-w", "-t", pane, "remain-on-exit", "failed")
        deadline = time.monotonic() + 15
        while not (run / "ready").exists():
            if (run / "startup-error").exists():
                raise RuntimeError((run / "startup-error").read_text().strip())
            if time.monotonic() >= deadline:
                raise RuntimeError("Runner did not become ready")
            time.sleep(0.05)
        capture = (
            "exec 3>> "
            + shlex.quote(str(run / "terminal.log"))
            + " && touch "
            + shlex.quote(str(run / "capture-ready"))
            + " && exec cat >&3"
        )
        tmux("pipe-pane", "-t", pane, capture)
        wait_for(run / "capture-ready")
        (run / "start").touch()
    except Exception:
        # The start gate was never released: no make process to interrupt.
        subprocess.run(
            ["tmux", "-L", SOCKET, "kill-session", "-t", "=" + session],
            capture_output=True,
            check=False,
        )
        if (run / "startup-error").exists():
            raise RuntimeError((run / "startup-error").read_text().strip()) from None
        raise
    print(f"Run: {run}\nWatch: tmux -L {SOCKET} attach-session -r -t {session}")
    print(f"Status: python3 {SELF} status {shlex.quote(str(run))}")
    print(f"Log: {run / 'terminal.log'}")


# OSC 8 hyperlinks (BitBake wraps log paths in them), then colour/cursor codes.
ANSI = re.compile(r"\x1b\][^\x1b\x07]*(?:\x1b\\|\x07)|\x1b\[[0-9;?]*[a-zA-Z]")
# BitBake prints the first form while it schedules tasks and the second once
# it stops scheduling: after Ctrl-C, a failed task or a disk-monitor stop.
BLOCK = re.compile(
    r"Currently +(\d+) +running tasks? +\((\d+) of (\d+)\)"
    r"|Waiting for +(\d+) +running tasks? +to finish"
)
# A task line may end in its own progress bar.
TASK_LINE = re.compile(r"^\s*\d+: (\S.*?)(?:\s+\d+% \|.*)?\s*$")
# Exit codes of `wait`. Timeout is its own code: "still running, keep waiting"
# must never be confused with "gone without a result, investigate".
WAIT_EXIT = {
    "succeeded": 0,
    "failed": 1,
    "interrupted": 2,
    "startup-failed": 2,
    "unknown/interrupted": 2,
}
WAIT_TIMEOUT_EXIT = 3


def clean_lines(text):
    return [
        ln for ln in ANSI.sub("", text).replace("\r", "\n").split("\n") if ln.strip()
    ]


def read_log(log, tail_bytes=None):
    with open(log, "rb") as fh:
        if tail_bytes:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - tail_bytes))
        return clean_lines(fh.read().decode("utf-8", "replace"))


def progress(log, tail_bytes=262144):
    """Latest BitBake task block of a terminal log, and the phase it shows."""
    try:
        lines = read_log(log, tail_bytes)
    except OSError:
        return None
    latest, tries = None, 3
    for i in range(len(lines) - 1, -1, -1):
        m = BLOCK.search(lines[i])
        if not m:
            continue
        waiting = m.group(4) is not None
        count = int(m.group(4) if waiting else m.group(1))
        tasks = []
        for line in lines[i + 1 : i + 1 + count]:
            t = TASK_LINE.match(line)
            if not t:
                break
            tasks.append(t.group(1))
        block = {"phase": "shutting-down" if waiting else "running", "running": count}
        if not waiting:
            block |= {"task": int(m.group(2)), "of": int(m.group(3))}
        block["tasks"] = tasks
        if latest is None:
            if not waiting and any("Keyboard Interrupt" in ln for ln in lines[i + 1 :]):
                block["phase"] = "shutting-down"
            # A block cut short by another message, or still being written,
            # lists fewer tasks than it counts; the block before it is whole.
            if len(tasks) == count or i == 0:
                return block
            latest = block
            continue
        if len(tasks) == count and block["phase"] == latest["phase"]:
            return block
        tries -= 1
        if tries == 0:
            break
    return latest


TASKS_SUMMARY = re.compile(r"NOTE: (Tasks Summary: .*)")
FAILED_HEADER = re.compile(r"^Summary: \d+ tasks? failed:")
FAILED_TASK = re.compile(r"^\s+(\S+:do_\S+)\s*$")
FAILED_LOG = re.compile(r"^\s+log: (\S+)")
TASK_ERROR = re.compile(r"^ERROR: Task \((\S+)\) failed")
DISK_STOP = re.compile(r"disk space monitor action is|No space left on device")
KAS_FAILED = re.compile(r'Command ".*" failed with error')
# Not anchored: the terminal echoes ^C in front of make's message.
MAKE_ERROR = re.compile(r"make(\[\d+\])?: \*\*\* .*")
ERROR_LINE = re.compile(r"^ERROR: |^\[[\w-]+\] ERROR")


def summarise_lines(lines, code, interrupted=False):
    """Failure kind and verdict-relevant excerpts of a finished run's log.

    BitBake's Tasks Summary is quoted, never trusted: it reads "all succeeded"
    after a disk-monitor stop, an interrupt, or a failing step outside BitBake.
    """
    summary, failed, errors, make_error = None, [], [], None
    for i, line in enumerate(lines):
        m = TASKS_SUMMARY.search(line)
        if m:
            summary = m.group(1)
        elif FAILED_HEADER.match(line):
            failed = []
            for entry in lines[i + 1 :]:
                task, log = FAILED_TASK.match(entry), FAILED_LOG.match(entry)
                if task:
                    failed.append({"task": task.group(1), "log": None})
                elif log and failed:
                    failed[-1]["log"] = log.group(1)
                else:
                    break
        elif found := MAKE_ERROR.search(line):
            make_error = found.group(0).strip()
        if ERROR_LINE.search(line) and line[:300] not in errors:
            errors.append(line[:300])
    if not failed:
        # No closing summary (a log cut short): fall back to the task errors.
        names = dict.fromkeys(m.group(1) for m in map(TASK_ERROR.match, lines) if m)
        failed = [{"task": name, "log": None} for name in names]
    if code == 0:
        kind = "ok"
    elif interrupted or code < 0 or any("Keyboard Interrupt" in ln for ln in lines):
        kind = "interrupted"
    elif any(DISK_STOP.search(ln) for ln in lines):
        kind = "disk-space"
    elif failed:
        kind = "task-failure"
    elif make_error and not any(KAS_FAILED.search(ln) for ln in lines):
        # make failed although no kas command did: a step outside BitBake.
        kind = "gate-failure"
    else:
        kind = "unknown"
    return {
        "kind": kind,
        "tasks_summary": summary,
        "failed_tasks": failed,
        "errors": errors[:5],
        "make_error": make_error,
    }


def summarise(log, code, interrupted=False):
    try:
        lines = read_log(log)
    except OSError:
        lines = []
    return summarise_lines(lines, code, interrupted)


def outcome(result):
    code = result["exit_code"]
    # A negative code is Popen's "killed by signal -code": an interrupted
    # build (Ctrl-C is -2), not a failing one. A non-zero exit after the
    # supervisor saw Ctrl-C is an interruption too.
    if code < 0 or (code != 0 and result.get("interrupted")):
        return "interrupted"
    return "succeeded" if code == 0 else "failed"


def result_state(run):
    result = json.loads((run / "result.json").read_text())
    if "kind" not in result and "summary_error" not in result:
        # A run recorded before the summary existed: derive it from the log.
        result |= summarise(
            run / "terminal.log", result["exit_code"], bool(result.get("interrupted"))
        )
    state = outcome(result)
    if state == "interrupted":
        code = result["exit_code"]
        return {
            "state": state,
            "signal": -code if code < 0 else signal.SIGINT.value,
            **result,
        }
    return {"state": state, **result}


def status_of(run):
    if not (run / "run.json").exists():
        return {"state": "unknown/interrupted", "error": f"no run.json in {run}"}
    meta = json.loads((run / "run.json").read_text())
    if (run / "result.json").exists():
        return result_state(run)
    if (run / "startup-error").exists():
        return {
            "state": "startup-failed",
            "error": (run / "startup-error").read_text().strip(),
        }
    # Always the socket the run was started on: a plain `tmux` talks to another
    # server and never finds the session.
    panes = session_panes(meta)
    if meta.get("pane"):
        # The build's own pane: a live split shell must not keep a dead run running.
        alive = panes.get(meta["pane"]) is False
    else:
        # Records without a pane id: any live pane in the session.
        alive = False in panes.values()
    if not alive:
        # The runner writes result.json before its pane dies; a result that
        # landed between the two checks above is the real outcome.
        if (run / "result.json").exists():
            return result_state(run)
        return {"state": "unknown/interrupted"}
    if not (run / "started.json").exists():
        return {"state": "starting"}
    state = {"state": "running", "progress": progress(run / "terminal.log")}
    stop = read_json(run / "stop-request.json")
    if stop:
        state["stop"] = stop
    return state


def session_panes(meta):
    """{pane id: dead} for the run's tmux session; empty when it is gone."""
    try:
        out = tmux(
            "list-panes",
            "-s",
            "-t",
            "=" + meta["session"],
            "-F",
            "#{pane_id} #{pane_dead}",
            socket=meta.get("tmux_socket"),
        )
    except subprocess.CalledProcessError:
        return {}
    rows = (line.split() for line in out.splitlines())
    return {row[0]: row[1] == "1" for row in rows if len(row) == 2}


def build_pane(meta):
    """The pane to interrupt: the recorded one, else the session's only pane."""
    if meta.get("pane"):
        return meta["pane"]
    panes = list(session_panes(meta))
    if len(panes) != 1:
        raise RuntimeError(
            f"Cannot identify the build pane of {meta['session']} (no pane id recorded, "
            f"{len(panes)} panes); interrupt it by hand in the attached session"
        )
    return panes[0]


def status(run):
    print(json.dumps(status_of(run)))


def wait(run, timeout, interval=5.0):
    """Block until the run ends, or timeout. Prints status JSON; returns WAIT_EXIT."""
    deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        state = status_of(run)
        if state["state"] in WAIT_EXIT:
            print(json.dumps(state))
            return WAIT_EXIT[state["state"]]
        if deadline is not None and time.monotonic() >= deadline:
            print(json.dumps(state | {"timeout": True}))
            return WAIT_TIMEOUT_EXIT
        time.sleep(
            interval
            if deadline is None
            else max(0.0, min(interval, deadline - time.monotonic()))
        )


def stop(run, reason, by):
    """Record why, then send one Ctrl-C to the run's build pane, once per run."""
    if not reason.strip():
        raise ValueError("--reason must say why the run is stopped")
    state = status_of(run)
    if state["state"] != "running":
        raise RuntimeError(f"Run is {state['state']}, not running; nothing to stop")
    meta = json.loads((run / "run.json").read_text())
    # BitBake owns shutdown: the first Ctrl-C finishes the running tasks, a
    # second terminates them. Only the first is sent from here.
    if (run / "stop-request.json").exists() or (run / "interrupt-seen").exists():
        raise RuntimeError(
            "The run was already interrupted and BitBake is shutting down; follow it "
            "with `wait`. A further Ctrl-C terminates its tasks: type it in the "
            "attached session (without -r)"
        )
    target = build_pane(meta)
    # Recorded before it is sent: the runner copies it into result.json.
    request = {"interrupts": [{"sent": now(), "reason": reason, "by": by}]}
    write_json(run / "stop-request.json", request)
    tmux("send-keys", "-t", target, "C-c", socket=meta.get("tmux_socket"))
    state = status_of(run)
    print(json.dumps(state))
    if state["state"] == "running":
        print(
            "agent-build: interrupt sent; BitBake finishes its running tasks before it exits. "
            "Follow with `wait`.",
            file=sys.stderr,
        )
    return 0


def run_record(run):
    """One list row: identity from run.json, outcome without reading the log."""
    meta = read_json(run / "run.json") or {}
    started = (read_json(run / "started.json") or {}).get("started")
    result = read_json(run / "result.json")
    state = outcome(result) if result is not None else status_of(run)["state"]
    end = (result or {}).get("finished")
    duration = (result or {}).get("duration_seconds")
    if duration is None and started:
        finish = dt.datetime.fromisoformat(end) if end else dt.datetime.now(dt.UTC)
        if end or state == "running":
            duration = round(
                (finish - dt.datetime.fromisoformat(started)).total_seconds(), 1
            )
    return {
        "run": run.name,
        "state": state,
        "kind": (result or {}).get("kind"),
        "board": meta.get("board"),
        "target": " ".join(meta.get("command", [])[1:]),
        "started": started or meta.get("created"),
        "duration_seconds": duration,
        "parent": meta.get("parent"),
    }


def span(seconds):
    if seconds is None:
        return "-"
    minutes, secs = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m" if hours else f"{minutes}m{secs:02d}s"


def list_runs(root, limit, as_json):
    base = runs_dir(root)
    runs = (
        sorted(
            (p for p in base.iterdir() if p.is_dir()),
            key=lambda p: p.name,
            reverse=True,
        )
        if base.is_dir()
        else []
    )
    rows = [run_record(run) for run in (runs[:limit] if limit else runs)]
    if as_json:
        print(json.dumps(rows, indent=2))
        return
    table = [("RUN", "STATE", "KIND", "BOARD", "STARTED (UTC)", "DURATION", "TARGET")]
    for row in rows:
        when = row["started"]
        if when:
            when = (
                dt.datetime.fromisoformat(when)
                .astimezone(dt.UTC)
                .strftime("%Y-%m-%d %H:%M:%SZ")
            )
        table.append(
            (
                row["run"],
                row["state"],
                row["kind"] or "-",
                row["board"] or "-",
                when or "-",
                span(row["duration_seconds"]),
                row["target"]
                + (f"  (parent {row['parent']})" if row["parent"] else ""),
            )
        )
    widths = [max(len(line[i]) for line in table) for i in range(len(table[0]) - 1)]
    for line in table:
        print(
            "  ".join(cell.ljust(width) for cell, width in zip(line, widths))
            + "  "
            + line[-1]
        )


def prune(root, dry_run):
    """Close the sessions of finished runs; report every other session."""
    try:
        listing = tmux("list-sessions", "-F", "#{session_name}\t#{" + RUN_OPTION + "}")
    except subprocess.CalledProcessError:
        listing = ""  # no server: no sessions
    closed, kept = [], []
    for line in filter(None, listing.splitlines()):
        session, _, recorded = line.partition("\t")
        if not session.startswith("build-"):
            kept.append({"session": session, "reason": "not a launcher session"})
            continue
        # Sessions older than the run option are looked up in this checkout.
        run = (
            Path(recorded)
            if recorded
            else runs_dir(root) / session.removeprefix("build-")
        )
        meta = read_json(run / "run.json")
        if meta is None or meta.get("session") != session:
            kept.append({"session": session, "reason": "no run record found"})
        elif not ((run / "result.json").exists() or (run / "startup-error").exists()):
            try:
                dead = (
                    "0"
                    not in tmux(
                        "list-panes", "-s", "-t", "=" + session, "-F", "#{pane_dead}"
                    ).split()
                )
            except subprocess.CalledProcessError:
                dead = False
            reason = (
                "pane ended without a result; inspect it before closing it by hand"
                if dead
                else "running"
            )
            kept.append({"session": session, "reason": reason, "run": str(run)})
        else:
            if not dry_run:
                tmux("kill-session", "-t", "=" + session)
            closed.append({"session": session, "run": str(run)})
    print(json.dumps({"dry_run": dry_run, "closed": closed, "kept": kept}, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(
        dest="action", required=True, metavar="{start,status,wait,stop,list,prune}"
    )

    def worktree(command):
        command.add_argument(
            "--worktree",
            default=str(SELF.parents[2]),
            help="checkout root (default: this script's)",
        )

    launch = sub.add_parser(
        "start", help="Launch make targets in a dedicated tmux session"
    )
    worktree(launch)
    launch.add_argument(
        "--parent",
        metavar="RUN",
        help="run id (or directory) this run resumes or retries; recorded in run.json",
    )
    launch.add_argument(
        "--artifact",
        action="append",
        default=[],
        metavar="GLOB",
        help="glob relative to the checkout; matching files are hashed into "
        "result.json when make exits 0 (repeatable)",
    )
    launch.add_argument(
        "--linger",
        type=float,
        metavar="SECONDS",
        default=float(os.environ.get("AGENT_BUILD_LINGER") or LINGER),
        help=f"keep the finished session open this long (default {LINGER}; "
        "AGENT_BUILD_LINGER overrides)",
    )
    launch.add_argument("topic")
    launch.add_argument("make_args", nargs=argparse.REMAINDER)
    sub.add_parser(
        "status", help="Print the run's state, phase and task progress as JSON"
    ).add_argument("run", type=Path)
    sub.add_parser("_run").add_argument("run", type=Path)
    sub.add_parser("_hold")
    waiter = sub.add_parser(
        "wait",
        help="Block until the run ends: exit 0 succeeded, 1 failed, "
        "2 interrupted/unknown/startup-failed, 3 timeout (still running)",
    )
    waiter.add_argument(
        "--timeout", type=float, default=None, help="seconds; default: no limit"
    )
    waiter.add_argument("--interval", type=float, default=5.0, help=argparse.SUPPRESS)
    waiter.add_argument("run", type=Path)
    stopper = sub.add_parser(
        "stop", help="Record a reason and send one Ctrl-C to the run's pane"
    )
    stopper.add_argument(
        "--reason",
        required=True,
        help="why the run is stopped; recorded in the run directory",
    )
    stopper.add_argument(
        "--by",
        default=os.environ.get("USER", "unknown"),
        help="who stops it (default: $USER)",
    )
    stopper.add_argument("run", type=Path)
    lister = sub.add_parser("list", help="Runs of a checkout, newest first")
    worktree(lister)
    lister.add_argument(
        "--limit", type=int, default=20, help="newest N runs (default 20; 0 for all)"
    )
    lister.add_argument("--json", action="store_true", help="JSON instead of a table")
    pruner = sub.add_parser("prune", help="Close the tmux sessions of finished runs")
    worktree(pruner)
    pruner.add_argument("--dry-run", action="store_true", help="report only")
    args = parser.parse_args()
    if args.action == "start":
        start(args)
    elif args.action == "status":
        status(args.run.resolve())
    elif args.action == "wait":
        return wait(args.run.resolve(), args.timeout, args.interval)
    elif args.action == "stop":
        return stop(args.run.resolve(), args.reason, args.by)
    elif args.action == "list":
        list_runs(args.worktree, args.limit, args.json)
    elif args.action == "prune":
        prune(args.worktree, args.dry_run)
    elif args.action == "_hold":
        time.sleep(60)
    else:
        return runner(args.run.resolve())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"agent-build: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        sys.exit(1)
