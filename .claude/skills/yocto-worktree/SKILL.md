---
name: yocto-worktree
description: "Sets up, seeds, coordinates, and cleans up isolated git worktrees for subagent or parallel Yocto work in this repo. Use when delegating build-running or build-polluting tasks to a subagent, running a parallel session alongside the main checkout, naming a worktree branch before opening a PR, or removing a locked agent worktree. Covers kas/local.yml seeding, shared-cache verification, and double-force cleanup."
metadata:
  argument-hint: "[setup|verify-cache|rename|cleanup]"
allowed-tools: "Read, Grep, Glob, Bash(git *), Bash(cp *), Bash(ls *), Bash(test *), Bash(. scripts/env.sh*), Bash(kas *), Bash(make *), Bash(gh *), Bash(.claude/skills/yocto-worktree/scripts/*)"
---

# Isolated Yocto worktrees (subagents & parallel sessions)

Companion to the "Parallel sessions — use git worktrees" section of
`CLAUDE.md`, which covers the operator-facing setup. This skill covers
what an agent has to get right: seeding, cache verification, and
cleanup.

## When to use a worktree (and when not)

Spawn subagents with `isolation: worktree` when the task:

- runs a build (anything invoking `make`/`bitbake`), or
- risks polluting `build/` or `.kas/` in the main checkout, or
- must run in parallel with the operator's own work in the main
  checkout.

Do **not** pay the worktree cost for read-only exploration or small
non-build edits — run those in place.

**Worktrees live inside the repo, under `.claude/`** — never as
siblings of the checkout:

- Agent-harness worktrees at `.claude/worktrees/agent-<id>/` on branch
  `worktree-agent-<id>` (what `isolation: worktree` creates).
- Operator worktrees alongside them, e.g. `.claude/worktrees/<topic>`.

Both need the seeding step below. Note `AGENTS.md` §"Branch strategy":
worktrees are an ephemeral concurrency tool, not a workflow tier.

## 1. Seed and verify — run the script

`kas/local.yml` is gitignored (`.gitignore:17`), so a fresh worktree
does **not** have it. Without it the Makefile falls back to
`BASE_DEFAULT = kas/base.yml:kas/machines/rzv2l.yml` (`Makefile:46-51`),
which builds correctly but **without the shared `DL_DIR`/`SSTATE_DIR`** —
a cold build of hours instead of the minutes an sstate-hit build takes.

Layer *setup* stays fast either way: `KAS_REPO_REF_DIR` defaults to
`/mnt/yocto-nvme/layers-wrynose` in both `Makefile:27` and
`scripts/env.sh`, so git alternates work without `local.yml`. It is only
sstate and downloads that go missing — which is the expensive half.

From the **main checkout root**:

```bash
.claude/skills/yocto-worktree/scripts/seed-and-verify.sh .claude/worktrees/agent-<id>
```

The script copies `kas/local.yml` into the worktree, then resolves
`DL_DIR`/`SSTATE_DIR` through kas (sourcing `scripts/env.sh` — agent
shells don't get direnv) and fails if either points inside the
worktree's own `build/`.

- Exit 0 — caches wired, safe to build.
- Exit 1 — prerequisites missing. If it reports `kas/local.yml` missing
  in the main checkout, **stop and ask the operator**; don't invent
  cache paths and don't start a cold build.
- Exit 2 — verification failed. Fix seeding and re-run. If it fails
  twice, stop and report: something structural is wrong, and repeated
  cold-build attempts are the expensive failure mode this skill exists
  to prevent.

`kas/local.yml` is the *entry point*, not an overlay — it composes base
plus machine through its own `includes:`. Don't append it to
`kas/base.yml:kas/machines/rzv2l.yml`; that double-composes.

Validate progressively before any image build: `make parse`, then the
affected recipe's task, then the image. Capability flags compose on the
build target, not the stack path — `make dev TPM=1 VIRT=1`.

## 2. Branch naming — before opening the PR

The default `worktree-agent-<id>` is opaque. Rename to this repo's
convention (`AGENTS.md` §"Branch strategy") **before** opening a PR:

- `<scope>/<topic>` for single-scope work — e.g.
  `bsp/init/persistence-refactor`
- `<type>/<topic>` when the change spans scopes — e.g.
  `feat/drpai-integration`

GitHub's branch-rename API auto-redirects refs, but it **auto-closes any
open PR whose head ref is the old name** — you can't reopen, because the
old ref is gone. So the order is:

1. `git branch -m <new>` locally
2. `git push -u origin <new>`
3. Delete the old remote ref (the local rename + push already moved the
   work), or `gh api repos/<owner>/<repo>/branches/<old>/rename -f new_name=<new>`
4. **Then** `gh pr create` against `main`

If the PR is already open under the old name, expect to close it and
re-open from the renamed branch with a "Supersedes #N" note.

Commits must satisfy the Conventional Commits `commit-msg` hook
(`.pre-commit-config.yaml`) — a worktree gets the same hooks, so a
malformed subject fails locally, not in CI.

## 3. Coordinating with a parallel session in the main checkout

A subagent in its own worktree and a session in the main checkout don't
share working-tree state — they can run truly in parallel. Discipline:

- The worktree agent owns its branch and its `build/`. Don't reach
  across.
- The main-checkout session continues on its own branch; do **not**
  `git rebase`/`pull` it while the parallel agent is mid-edit. Wait for
  `git status` to be clean.
- Once the worktree's PR merges to `main`, rebase the main-checkout
  branch onto `main`. `main` is protected and linear. If neither branch
  touched the same paths the rebase is conflict-free — verify with
  `git diff origin/main...<branch> --name-only` against the merged paths
  first.

Concurrent builds share `SSTATE_DIR`. BitBake serialises sstate writes
via `sstate.lock`; writes don't corrupt, but two builds hitting the same
recipe queue briefly on the lock.

Before any destructive move (`rm -rf`, `make purge`, branch resets),
run the collision checks in `CLAUDE.md` §"Mid-session collision
detection". Default to pausing and asking.

## 4. Cleanup

`git worktree remove` may refuse with `cannot remove a locked working
tree, lock reason: claude agent agent-<id> (pid …)` even after the agent
process has exited. The lock is the agent harness's, not git's, and
persists past the process. Use double-force:

```bash
git worktree remove -f -f .claude/worktrees/agent-<id>
```

This removes both the worktree directory and its branch metadata.
Confirm with `git worktree list`.

Never `rm -rf` a worktree directory directly — git's worktree metadata
goes stale and later `git worktree` operations misbehave.

## Safety rails / stopping conditions

- Don't launch full-image builds to validate recipe-level edits —
  progressive validation first.
- Don't clean up worktrees, branches, or build state you didn't create;
  surface them to the operator instead.
- Stop and report if seed-and-verify fails twice (see step 1).
- `git add`/`commit`/`branch`/`tag` need operator confirmation in this
  repo (`CLAUDE.md` §"Operational notes") — that applies inside a
  worktree too.
