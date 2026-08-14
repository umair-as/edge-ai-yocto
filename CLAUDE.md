# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

Project orientation, build commands, repo layout, conventions, and
task routing live in the agent-agnostic file:

@AGENTS.md

The rest of this file is Claude-Code-specific tooling that does not
apply to other agents.

## Skills available

`.claude/skills/` holds two repo-local skills:

- `devtool-workflow` — iterating on recipe source (U-Boot,
  `linux-renesas`, app) via `devtool` instead of hand-editing patches.
  Cited as a field guide by `.claude/rules/yocto-patterns.md` ("Patch
  iteration — when to reach for devtool").
- `yocto-worktree` — isolated worktrees for subagent/parallel builds:
  `kas/local.yml` seeding, shared-cache verification, branch naming
  before PR, locked-worktree cleanup. Companion to §"Parallel sessions"
  below.

Where a skill and `.claude/rules/` ever disagree, **the rules win** —
they are repo-specific and wrynose-current.

## Serial console MCP

`mcp-serial-rs` gives direct UART access to the board
(`serial_list_ports`, `serial_open`, `serial_exec`,
`serial_read_until`). Prefer it over asking the operator to relay
console output — especially for U-Boot work and for boot states where
sshd is not up. The board's USB-serial adapter enumerates as
`/dev/ttyUSB0`, 115200 baud.

- The device cannot be shared: `serial_close` before the operator
  starts `tio`, and expect open to fail while a `tio` session holds
  the port.
- When grepping operator-captured `tio` logs, the file can contain
  high-bit control bytes that make vanilla `grep` treat it as binary
  and silently skip lines. Use `grep -a` or `strings <log> | grep …`
  so U-Boot/firmware output isn't filtered out.

## Permission allowlist

`.claude/settings.local.json` is the per-user allowlist. The
scaffold did not seed it; tune it yourself or use
`/fewer-permission-prompts` after a couple of sessions to derive a
list from actual usage.

## Parallel sessions — use git worktrees

This repo is frequently driven by more than one Claude instance at
once (e.g. one doing a layer port while another is shaping the build
plumbing). When that happens, every concurrent session MUST work in
its own git worktree, not the main checkout. Two agents editing the
same working tree race each other on file writes, on `.kas/` state,
and on `build/conf/` regeneration; recovery via rebase or reflog gets
ugly fast.

### Setting up worktrees (operator)

Worktrees live **inside the repo, under `.claude/worktrees/`** — not as
siblings of the checkout. That keeps them next to the agent-harness
worktrees `isolation: "worktree"` creates, and out of the parent
directory.

```bash
# From the repo root:
git worktree add .claude/worktrees/<topic> -b <topic>
```

`cd` into the worktree and spawn the Claude instance there. Each
worktree gets its own working tree, its own `.kas/`, its own `build/`.
Clean up when the topic merges:

```bash
git worktree remove .claude/worktrees/<topic>
```

For task-scoped subagents spawned from inside one session, prefer
`isolation: "worktree"` on the Agent tool rather than running them
in-place against the same tree.

### Seed `kas/local.yml` first — a fresh worktree does not have it

`kas/local.yml` is gitignored (`.gitignore:17`), so **it does not exist
in a new worktree**. Without it the Makefile falls back to
`BASE_DEFAULT = kas/base.yml:kas/machines/rzv2l.yml` (`Makefile:46-51`)
and the build runs with no shared `DL_DIR`/`SSTATE_DIR` — cold, hours
instead of minutes. Nothing warns you; it just builds slowly.

Seed and verify before the first build, from the main checkout root:

```bash
.claude/skills/yocto-worktree/scripts/seed-and-verify.sh <worktree-dir>
```

See the `yocto-worktree` skill for exit-code handling and cleanup. If
the script reports `kas/local.yml` missing in the *main* checkout, stop
and ask the operator — do not invent cache paths.

Layer setup stays fast regardless: `KAS_REPO_REF_DIR` defaults to
`/mnt/yocto-nvme/layers-wrynose` in `Makefile:27` and `scripts/env.sh`,
so git alternates work without `local.yml`. Only sstate and downloads
go missing — the expensive half.

### Once seeded, the first build is fast (sstate reuse)

Sstate keys are recipe task *signatures* — a hash of recipe content,
variables, and source inputs — not build paths. A seeded worktree shares
`SSTATE_DIR` and `DL_DIR` (operator-set to a shared fast-storage cache in
`kas/local.yml`) with the main checkout, so a build started right after a
recent full build on main is almost entirely a sstate restore: bitbake
re-links task outputs from that cache rather than recompiling. Expect
minutes, not hours.

What the first `make base` in a new worktree actually pays:

- **kas layer setup** — clones/checks out upstream layers into `.kas/`.
  `KAS_REPO_REF_DIR` (operator-set to a host-local layer cache) supplies
  git alternates; object copy from local disk, no network fetch. Seconds
  per layer.
- **sstate restore** — bitbake populates `build/tmp/` from sstate for
  every recipe whose signature matches. File copies from NVMe, not
  compiles.
- **recipe rebuild** — only recipes modified in the worktree miss sstate
  and actually compile.

Concurrent builds (worktree + main) share the same `SSTATE_DIR`.
Bitbake serialises sstate writes via `sstate.lock`; writes don't
corrupt, but two builds hitting the same recipe simultaneously queue
briefly on the lock.

### Mid-session collision detection

Before starting build-running or build-polluting work, or a substantial
multi-file change (not just when spawning a subagent), run `git status`
first. If unrelated uncommitted changes from a different thread are
already sitting in the tree, don't silently add to them — flag it and
ask whether the new work should go in its own worktree instead. Skip
this for minimal/single-file changes.

Before any destructive move (`rm -rf <anything>`, `make purge`, mass
file deletions, branch resets), check for signs of another instance:

- `git status` — uncommitted state you didn't author.
- `git log --oneline -20` — recent commits with unfamiliar topic.
- `.kas/`, `build/`, root-level upstream layer clones — kas-touching
  activity may be live from another shell.
- Open editor lockfiles, `.swp` files, `*.lock` files newer than your
  session start.

If signs are present:

1. Stop. Surface what you found to the operator before acting.
2. Do **not** clean up state you didn't create. A "stale" upstream
   clone at repo root may be another instance's in-flight work; a
   "stale" `build/conf/` may belong to a build the other instance
   has running.
3. Confirm with the operator whether to:
   - Move your work into a worktree before continuing, or
   - Pause until the other session lands, or
   - Proceed on a tightly-scoped change that doesn't touch shared paths.

Default to pausing. The cost of asking is one round-trip; the cost of
overwriting another agent's diff is much higher.

## Operational notes

- **Long-running builds.** `bitbake edge-image-base` from cold cache
  takes 1-3 hours. Run via `make` (which wraps `kas shell -c`) and
  let it complete; do not poll.
- **Upstream layers are kas-managed under `.kas/`.** `meta-renesas`,
  `bitbake`, `openembedded-core`, and the rest land in `.kas/` (the
  KAS work dir; gitignored) after the first kas invocation, pinned per
  `kas/base.yml`. Don't edit them by hand — kas resets on each run.
  See `docs/adr/0002-layer-hosting.md`.
- **Git workflow lives in `AGENTS.md`** (Commit style + Branch
  strategy). Do not run `git add`, `git commit`, `git branch`,
  `git tag`, or other state-changing git commands without operator
  confirmation. If a change feels like it warrants a commit, stop and ask.
- **Commit trailers.** The canonical rule is `AGENTS.md` §"Commit style →
  AI attribution": an `Assisted-by: <tool>:<model-id>` line per model that
  touched the change. From Claude Code that is
  `Assisted-by: claude-code:<the model id you are running as>`.

  **Do not copy a model name from this file.** This bullet deliberately
  contains no literal model id: an earlier revision pinned one, and it was
  already two releases stale before anyone noticed. Read your own model
  identity from your instructions and write that.

  **Do not add `Co-Authored-By:` for an AI tool** — not in commits, not
  in PR bodies. This overrides the harness default, which emits one;
  drop that line along with the generated-with footer. The why and the
  applicability date live in `AGENTS.md` §"Commit style → AI
  attribution".
