# CLAUDE.md

Claude-Code-specific notes layered on top of `AGENTS.md`. Read
`AGENTS.md` first.

## Skills available

`.claude/skills/` is intentionally empty for now. The Yocto/BSP
capabilities this repo leans on are provided today by shared,
repo-agnostic skills at the operator's global Claude Code level;
repo-local skills get factored into this directory as they solidify
for this project.

Reach for these shared, repo-agnostic skills when relevant:
- `build-image` — wraps the `make`/`kas`/`bitbake` flow.
- `add-package` — recipe + image-recipe edits for adding software.
- `create-kernel-fragment` — for kernel config fragments (new driver
  support, feature sets).
- `debug-bitbake` — for parse/build failures.
- `patch-kernel-bsp`, `patch-uboot-bsp` — when board patches land.
- `devtool-workflow` — for iterating on recipes pulled in from upstream
  sources before they're finalized in tree.

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

```bash
# From the repo root:
git worktree add ../edge-ai-yocto-<topic> -b <topic>
```

`cd` into the worktree and spawn the Claude instance there. Each
worktree gets its own working tree, its own `.kas/`, its own `build/`.
Caches (`KAS_REPO_REF_DIR`, `DL_DIR`, `SSTATE_DIR`) are host-shared
across worktrees — that's the speed win — but per-worktree tooling
state stays isolated. Clean up when the topic merges:

```bash
git worktree remove ../edge-ai-yocto-<topic>
```

For task-scoped subagents spawned from inside one session, prefer
`isolation: "worktree"` on the Agent tool rather than running them
in-place against the same tree.

### First build in a worktree is fast (sstate reuse)

Sstate keys are recipe task *signatures* — a hash of recipe content,
variables, and source inputs — not build paths. A new worktree shares
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
