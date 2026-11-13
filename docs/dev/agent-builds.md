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
(default `rzv2l`), so every run records its board. `start --worktree PATH`
selects another checkout.

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

## The run record

| File | Content |
|---|---|
| `run.json` | command, board, build directory, worktree, tmux session, forwarded environment, and `source`: commit, branch and dirty files at launch |
| `started.json` | written when make actually started |
| `result.json` | make's exit code and finish time |
| `terminal.log` | the pane's output |

Only a recorded exit code of 0 means success. A negative code means make was
killed by that signal (`-2` is Ctrl-C); `status` reports it as `interrupted`.
A missing `result.json` with a dead or missing pane is `unknown/interrupted`.
Logging can fail independently of the build (a full filesystem, for example),
so a successful build is not proof of a complete log.

`source` in `run.json` ties the run to the commit it built. A run with dirty
files did not build that commit alone.

## One build at a time

The launcher refuses a target that runs bitbake (`dev`, `bundle`, `parse`, …)
while any bitbake or kas process runs on the host, whatever its board: the
constraint is host resources. It also holds `build/<BOARD>/.agent-build.lock`
for the whole run, so two launcher runs never share a build directory. Direct
`make` or `kas` invocations do not take that lock; bitbake's own lock still
applies. Never remove bitbake's lock automatically.

## Interrupt and clean up

To interrupt a build on purpose, attach without `-r` and press Ctrl-C. After a
run has finished, remove its retained session (the logs stay):

```bash
tmux -L edge-builds kill-session -t build-<run-id>
```

Do not kill a running session as routine cleanup, and never use `kill-server`:
it ends every build on the socket.

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

It runs dummy make targets (no BitBake): success and failure, make's exit status,
first and last output, a real terminal, `VAR=value` forwarding, `BOARD` and the
build directory, a path with spaces, duplicate rejection, refusal while a
bitbake process runs, survival after the launcher exits, Ctrl-C, and a missing
result. It does not simulate termination of a whole agent harness or host
session.
