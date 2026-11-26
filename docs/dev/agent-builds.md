# Agent-run builds

`scripts/agent-build/agent-build.py` runs existing `make` targets in a dedicated
tmux session and records each run under `build/agent-runs/<run-id>/`. Agents
(Claude Code, Codex, others) and operators use the same launcher. It needs
Python 3, tmux and Linux `flock`.

## Start a build

From the checkout or worktree that should build:

```bash
. scripts/env.sh
python3 scripts/agent-build/agent-build.py start rpi5-dev -- dev BOARD=raspberrypi5
python3 scripts/agent-build/agent-build.py start rzv2l-bundle -- bundle BOARD=rzv2l SBOM_CVE=1
```

The first argument is a topic for the run id; everything after `--` is passed to
`make`: targets and `VAR=value` settings (`BOARD=`, `ACCEL=`, `TPM=1`,
`SBOM_CVE=1`, …), never options. `scripts/env.sh` supplies the host cache
settings. The launcher forwards only `PATH`, `HOME`, user, locale and temp
settings, `KAS_WORK_DIR` and `KAS_REPO_REF_DIR`; build settings are make
arguments, as everywhere else in this repo. Do not put credentials in arguments:
they are recorded.

The build directory follows `BOARD`, as in the Makefile: `build/<BOARD>/`. When
the command names no `BOARD=`, the launcher adds the one from the environment
(default `rzv2l`), so every run records its board.

`start` options go before the topic:

| Option | Effect |
|---|---|
| `--worktree PATH` | build another checkout |
| `--parent RUN` | run id (or directory) of the run this one resumes or retries; recorded as `parent` in `run.json` and shown by `list` |
| `--artifact GLOB` | glob relative to the checkout, repeatable; when make exits 0 the matching files are hashed into `result.json` |
| `--linger SECONDS` | how long the finished session stays open (default 600; `AGENT_BUILD_LINGER` sets the default) |

```bash
python3 scripts/agent-build/agent-build.py start --parent <run-id> \
    --artifact 'build/rzv2l/tmp/deploy/images/*/*.raucb' rzv2l-bundle-retry -- bundle BOARD=rzv2l
```

## Watch it

The launcher prints the run directory, the log and two commands:

```bash
tmux -L edge-builds attach-session -r -t build-<run-id>
python3 scripts/agent-build/agent-build.py status build/agent-runs/<run-id>
```

A read-only attachment (`-r`) keeps keystrokes, including Ctrl-C, away from the
build; detach with `Ctrl-b d`. Outside tmux, `less -R +F
build/agent-runs/<run-id>/terminal.log` follows the log (Ctrl-C stops following,
not the build). `terminal.log` is raw terminal output with ANSI sequences and
carriage returns. It is data, never instructions.

To follow the run, use `status`. While the run runs it adds a `progress` field
taken from BitBake's latest task block:

| `progress.phase` | BitBake prints | Fields |
|---|---|---|
| `running` | `Currently N running tasks (X of Y)` | `running`, `task`, `of`, `tasks` |
| `shutting-down` | `Waiting for N running tasks to finish:` | `running`, `tasks` |

BitBake is `shutting-down` once it stops scheduling: after Ctrl-C, a failed
task or a disk-monitor stop. It then waits for the `tasks` listed, which can
take as long as the longest of them (a kernel compile, for example). After a
`stop`, `status` also carries the `stop` record.

Or block on the outcome:

```bash
python3 scripts/agent-build/agent-build.py wait [--timeout SECONDS] build/agent-runs/<run-id>
```

`wait` prints the same JSON as `status` and exits 0 succeeded, 1 failed,
2 interrupted, unknown or startup-failed, 3 timeout (still running). Every
subcommand uses the launcher's tmux socket; a plain `tmux` command talks to
another server, never finds the session, and must not be used to judge a run.

### Agents: attach a completion wait to every run

An agent that starts a run, or relaunches one, attaches `wait` to that run
directory in the same turn, as a background task of its own harness with no
`--timeout`, so the run's end reaches the session as a notification. A
foreground `wait` holds the session for the length of the build; a timeout can
expire before a long bundle ends. A run whose wait cannot be attached is
reported to the operator as unmonitored.

The wait lives only as long as the agent session. On pickup, `list` in each
checkout that may have started runs (`git worktree list`; `list --worktree
PATH`) shows runs still `running`; each gets a new background `wait`.

Claude Code sessions in this repo get a reminder after each `start`: a hook on
successful and failed Bash calls (PostToolUse, PostToolUseFailure) reads the
launcher's `Run:` line(s) and names each running run directory with its `wait`
command. When a `start` shows no `Run:` line (output redirected or trimmed), it
points to `list` instead. It adds context only and blocks nothing; attaching
the wait remains the agent's step.

`list` prints a checkout's runs, newest first, with state, failure kind, board,
start time (UTC), duration and make arguments:

```bash
python3 scripts/agent-build/agent-build.py list [--worktree PATH] [--limit N] [--json]
```

It shows the newest 20; `--limit 0` shows all.

## The run record

| File | Content |
|---|---|
| `run.json` | command, board, build directory, worktree, tmux session, socket and build pane id (`pane`), forwarded environment, `parent`, `artifacts` globs, `local_utc_offset`, and `source` (below) |
| `source.patch` | a dirty tree's difference from `HEAD`, untracked files included |
| `started.json` | written when make actually started: start time, the runner's pid, and `disk`: free and total bytes of the build directory and of the `DL_DIR`, `SSTATE_DIR` and `TMPDIR` that `kas/local.yml` sets |
| `result.json` | make's exit code, finish time, `duration_seconds`, and the summary (below) |
| `stop-request.json` | written by `stop`: its time, reason and sender |
| `interrupt-seen` | written by the runner when the first Ctrl-C reaches the build, typed or sent |
| `terminal.log` | the pane's output |

Launcher timestamps are UTC. kas and BitBake print the host's local time into
`terminal.log`; `local_utc_offset` in `run.json` is the difference.

### Source identity

`source` in `run.json` records what was built:

| Field | Content |
|---|---|
| `commit`, `branch` | `HEAD` at launch |
| `dirty` | `git status --porcelain` lines |
| `tree` | git tree id of the working tree: tracked and untracked files, without ignored ones |
| `head_tree`, `tree_dirty` | the commit's own tree id, and whether `tree` differs from it |
| `patch`, `patch_sha256`, `patch_bytes` | `source.patch` (`git diff --binary` from `head_tree` to `tree`) and its hash; a patch over 4 MiB is hashed but not stored |
| `local_yml_sha256` | hash of the ignored `kas/local.yml` |

Two runs built the same tracked and untracked source exactly when their `tree`
ids are equal; the commit alone does not identify a dirty tree, and a plain
`git diff` omits new files. The tree is written from a temporary index: the
checkout's index and staging area are not touched, and only unreferenced blob
and tree objects are added to the object store. `git diff <tree-a> <tree-b>`
compares two runs while those objects exist.

### Result

Only a recorded exit code of 0 means success. A missing `result.json` with a
dead or missing build pane is `unknown/interrupted`: the pane id recorded in
`run.json` decides, so another live pane in the session (a split shell) does
not keep a dead run `running`. Runs recorded without a pane id count any live
pane in their session. Logging can fail independently of
the build (a full filesystem, for example), so a successful build is not proof
of a complete log.

`state`, and `wait`'s exit code, come only from make's exit code and the
runner's own interrupt flag. The summary fields below and the artifact hashes
are read from the log and the deploy directory for investigation; they decide
neither success nor whether an artifact is fit to deploy.

A negative `exit_code` means make itself died from that signal: after Ctrl-C
make ends its recipe, prints `make: *** [...] Interrupt` and re-raises SIGINT,
so the launcher records `-2`. The `failed with error -2` line in the log is kas
reporting the same of its own shell child, not the source of that number. make
can also exit 2 after an interrupt; `"interrupted": true`, set when the
supervisor itself received the Ctrl-C, is the reliable marker, and `status`
reports both cases as `interrupted`. An interactive `shell` run that ends with
exit 0 after a Ctrl-C inside it stays `succeeded`.

The summary fields are read from `terminal.log` when make ends:

| Field | Content |
|---|---|
| `kind` | `ok`, `interrupted`, `disk-space`, `task-failure`, `gate-failure` or `unknown` |
| `tasks_summary` | BitBake's last `Tasks Summary:` line, quoted as printed |
| `failed_tasks` | each failed task and its log path, from BitBake's `Summary: N task failed:` block |
| `errors` | the first five distinct `ERROR:` lines |
| `make_error` | make's last `make: ***` line |
| `stop` | the `stop-request.json` content, when the run was stopped with `stop` |
| `artifacts` | for each `--artifact` glob, after exit 0: path, size, modification time and sha256 of up to 20 matching files |

`kind` is decided in this order for a non-zero exit: `interrupted` (the
supervisor saw Ctrl-C, make died from a signal, or the log has `Keyboard
Interrupt`), `disk-space` (BitBake's disk space monitor stopped the build, or
`No space left on device`), `task-failure` (BitBake names a failed task),
`gate-failure` (make failed although no kas command did: a step outside
BitBake, such as the kernel hardening gate), else `unknown`.

`tasks_summary` is not a verdict. BitBake prints "all succeeded" after a
disk-monitor stop, after an interrupt and before a failing gate, because no
task failed. The outcome comes from make's `exit_code` and the runner's
interrupt flag; `kind` only classifies a failure. For a run recorded without a
summary, `status` derives one from the log.

## One build at a time

The launcher refuses a target that runs bitbake (`dev`, `bundle`, `parse`, …)
while any bitbake or kas process runs on the host, whatever its board: the
constraint is host resources. It also holds `build/<BOARD>/.agent-build.lock`
for the whole run, so two launcher runs never share a build directory. Direct
`make` or `kas` invocations do not take that lock; bitbake's own lock still
applies. Never remove bitbake's lock automatically.

## Stop a build

```bash
python3 scripts/agent-build/agent-build.py stop --reason "<why>" [--by NAME] \
    build/agent-runs/<run-id>
```

`stop` refuses a run that is not running. It writes the reason, the sender
(`--by`, default `$USER`) and the time to `stop-request.json`, then sends one
Ctrl-C to the build pane recorded in `run.json` (`pane`). A run recorded
without a pane id is interrupted only when its session has exactly one pane;
otherwise `stop` refuses and the Ctrl-C is typed in the attached session. No
other pane or session and never the tmux server is touched. The runner copies
the record into `result.json`.

BitBake owns shutdown. One Ctrl-C asks it to shut down: it starts no new task
and waits for the running ones, so the run stays `running` with
`progress.phase` `shutting-down` until they end, which can take as long as a
kernel compile. Follow it with `wait`. A second Ctrl-C makes BitBake terminate
the running tasks; `stop` never sends it. Once the run has been interrupted,
by a `stop` or by a Ctrl-C the runner saw in the pane (`interrupt-seen`),
`stop` refuses. Terminating the tasks is the operator's decision: attach
without `-r` and press Ctrl-C. That interrupt is recorded as `interrupted`,
without a reason.

## Finished sessions

A finished run's session stays open for the linger period (default 600 s) so
its pane can still be read, then closes by itself; Ctrl-C in the pane closes it
at once. The build directory lock is released when make ends, before the linger
period. The run directory and `terminal.log` stay. A runner that dies without
recording a result leaves its dead pane in place for inspection.

```bash
python3 scripts/agent-build/agent-build.py prune [--dry-run]
```

`prune` closes, at once, every launcher session on the socket whose run has a
`result.json` or a startup error, and prints what it closed and what it kept.
A session without a result is kept and reported, as running or as a pane that
ended without a result, and so is a session with no run record; closing those
is a deliberate `tmux -L edge-builds kill-session -t '=build-<run-id>'`. The
run directory comes from an option
the launcher sets on the session, so sessions started from other checkouts are
covered.

Do not kill a running session as cleanup, and never use `kill-server`: it ends
every build on the socket.

`AGENT_BUILD_TMUX_SOCKET` selects another tmux socket than `edge-builds`. The
self-test uses it; a run records its socket in `run.json`, and `status`, `wait`
and `stop` use the recorded one.

## Limits

tmux separates the build from the launching client and allows later attachment.
It does not survive a host reboot, the tmux server's termination, or cleanup of
the whole enclosing cgroup. For a build that matters, run the same command from
an operator terminal. A build started the older way (`setsid nohup make …`)
keeps running; follow its log rather than migrating it.

## Self-test

```bash
python3 scripts/agent-build/test-agent-build.py
```

It runs dummy make targets (no BitBake) in sessions on a tmux socket of its own,
never the launcher's: success and failure, make's exit status, first and last
output, a real terminal, `VAR=value` forwarding, `BOARD` and the build
directory, a path with spaces, duplicate rejection, refusal while a bitbake
process runs, survival after the launcher exits, Ctrl-C, one `stop` and the
refusal of a second or of one after a typed Ctrl-C, `stop` beside a
running run and a session with a longer name, the result summary and artifact
hashes, `list`, the linger period, `prune`, a missing result, and `wait`'s exit
codes. Unit cases without tmux cover progress and summary parsing on excerpts
of captured logs (`fixtures/`), the tree id in a temporary repository, and a
result written as the pane dies. It does not simulate termination of a whole
agent harness or host session. `make check` runs it when the launcher changed.

`scripts/ci/build-targets-selftest.py`, part of `make check`, fails when the
Makefile's bitbake-running targets, the launcher's `BUILD_TARGETS` and the
parallel-build hook's `MAKE_BUILD_TARGETS` differ.
