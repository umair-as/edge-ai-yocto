# AGENTS.md

Canonical orientation for AI coding agents working in this repo.
Agent-agnostic: Claude Code, Codex, Cursor, Copilot, etc. Claude-
specific extras (skills, MCP servers) live in `CLAUDE.md`.

## What this repo is

This project is agent-driven. Its commits, patches and docs are written by
AI coding agents (Claude Code, Codex, Kiro) under the maintainer's direction
and review; the maintainer is the commit author and answers for every
change. Because that holds for the whole repository, individual commits do
not carry an AI attribution trailer (§"AI attribution").

See [README.md](README.md) for the platform summary. Short version:
KAS-driven Yocto 6.0 (wrynose) build, custom `edge-ai` distro, and a
per-board vendor BSP and kernel (ADR-0011): the Renesas RZ/V2L SMARC EVK
on the CIP-aligned `linux-renesas` 6.12 (the SLTS intent of ADR-0001), the
Raspberry Pi 5 on mainline-stable 6.18. `BOARD=<name>` selects the board.

**Scale.** This is a personal portfolio project. The engineering follows best
practice (validation, SBOM/CVE, signed updates), but process is sized to one
maintainer, not to a production release cycle. When a step costs more in
downloads, rebuilds or triage time than it demonstrates, use the lighter variant
that still shows the practice, and say which one was used.

## Build commands

Always prefer `make` over raw `kas`/`bitbake` — the wrapper resolves
the composition for you.

```bash
make help                 # authoritative target catalogue — check before raw bitbake
make base                 # build edge-image-base (the v0 wired tier)
make base BOARD=raspberrypi5   # same for the second board; builds in build/raspberrypi5/
make dev | prod           # dev / hardened-prod image tiers
make bundle               # RAUC .raucb for OTA install
make parse                # bitbake -p (parse-only sanity — cheapest validation)
make preflight            # cheapest checks for the changed paths before a build;
                          #   PREFLIGHT_ARGS=--bitbake runs targeted tasks (docs/dev/ci.md)
make check                # pre-PR gate: repo invariants, shellcheck, host selftests (no kas)
make ci                   # parse-check the committed origin/main in a worktree and
                          #   post GitHub commit statuses (docs/dev/ci.md)
make kernel-hardening-check  # export the prod kernel .config (configure only) and run
                          #   the KSPP gate on it (docs/security/kernel-config/)
make layers               # bitbake-layers show-layers
make shell                # interactive KAS shell
make clean-lock           # remove a stale build/bitbake.lock
```

Capability toggles are **make flags, not shell environment**:

```bash
make dev ACCEL=drpai-v2l         # select an accelerator stack
make dev TPM=1                   # + meta-secure-core (TPM2 + IMA/EVM)
make dev JTAG=1 BPF=1            # flags compose freely
make dev LAYOUT=emmc             # GPT + systemd-repart eMMC layout (remembered per build dir)
make bundle IMAGE=prod           # bundle the prod image at the prod tier
```

Full flag and setting catalogue: `make help`; the mechanics are in
[docs/dev/build-system.md](docs/dev/build-system.md). A bare `EDGE_*=1`
exported in the shell is **dropped** — kas forwards only the build settings
listed under `env:` in `kas/base.yml`, and the Makefile `unexport`s those, so
every toggle goes through a make flag (a kas fragment) or a make setting.

## KAS composition

```
kas/base.yml         <- distro + upstream layer wiring; board-neutral (no kernel, no vendor BSP)
kas/bsp/*.yml        <- vendor BSP + kernel provider per board family (renesas-rz.yml, raspberrypi.yml)
kas/machines/*.yml   <- board pick; includes its kas/bsp fragment (rzv2l.yml, raspberrypi5.yml)
kas/accel/*.yml      <- accelerator selection, composed by the machine fragment (drpai-v2l.yml)
kas/local.yml        <- personal overlay (paths, parallelism); gitignored
kas/local.yml.example <- template
```

Compose with `:`:

```
kas build kas/base.yml:kas/machines/rzv2l.yml
kas build kas/base.yml:kas/machines/raspberrypi5.yml
# Image tier is picked via the bitbake target name (edge-image-base /
# edge-image-dev), not a kas overlay; the make wrapper handles this.
```

Board facts (slot devices, U-Boot env area, FIT addresses, boot files) live
in `meta-edge-bsp/conf/machine/include/edge-board-<MACHINE>.inc`, pulled in
by MACHINE from the distro conf. Build directories are per board, `build/<BOARD>/`,
sharing `DL_DIR`/`SSTATE_DIR`.

The Makefile always composes the tracked chain
(`kas/base.yml:kas/machines/$(BOARD).yml`) and appends `kas/local.yml` last,
as an additive host overlay, when it exists. A host file never decides the
board.

### Standalone `kas` invocations — source the env first

The Makefile exports `KAS_WORK_DIR`/`KAS_BUILD_DIR`/`KAS_REPO_REF_DIR`
only to its own sub-processes. A bare `kas shell …` in any other shell
falls back to kas' default `KAS_WORK_DIR = CWD` and **re-clones the
entire upstream layer stack into the repo root**. When a raw kas call
is unavoidable (e.g. `bitbake -e` variable inspection), source the env
in the same command:

```bash
export BOARD=rzv2l        # or raspberrypi5
. scripts/env.sh && kas shell -c 'bitbake-getvar -r u-boot SRC_URI' \
    kas/base.yml:kas/machines/$BOARD.yml:kas/local.yml
```

`scripts/env.sh` reads `BOARD` and sets `KAS_BUILD_DIR` to the board's build
directory (`build/<BOARD>/`), as the Makefile does. Pass the full chain: `kas/local.yml` is an additive host
overlay with no `includes:` (a host file never decides the board), so
`kas shell kas/local.yml` alone loads no layers and fails with "Did not find
any init-build-env script". Capability flags add their fragments to the chain;
`make -n <target> BOARD=<board> <FLAGS>` prints the exact command.

Interactive shells get this automatically via `.envrc` (direnv, after a
one-time `direnv allow`). Non-interactive shells — including AI-agent
tool shells, CI steps, and scripts — do **not** trigger direnv and must
source `scripts/env.sh` explicitly or go through `make`. If the
accident happens anyway: the stray root clones are untracked; confirm
`build/conf/bblayers.conf` points at `.kas/` before deleting them.

## Repo layout (orient yourself fast)

```
README.md                              # platform summary
AGENTS.md                              # this file
CLAUDE.md                              # Claude-Code-specific extras
Makefile                               # build wrapper around kas
kas/                                   # KAS composition
.github/workflows/                     # release notes on tag push (docs/dev/ci.md)
scripts/ci/                            # check.sh + repo-lint.sh (`make check`), local-check.sh (`make ci`),
                                       #   preflight.py (`make preflight`), kernel-config-export.sh
scripts/agent-build/                   # build launcher: make in a logged tmux session
                                       #   (docs/dev/agent-builds.md)
docs/
  adr/                                 # Architecture Decision Records — read
                                       #   before re-deriving settled choices.
                                       #   0001 = RZ/V2L kernel base (linux-cip 6.12 SLTS);
                                       #   0011 = kernel base is per board.
.claude/
  context/bsp-workflow.md              # layer ownership + workflow contract
  references/board-catalogue.md        # boards wired vs. slot-available
  rules/yocto-patterns.md              # wrynose features, SBOM/CVE wiring, pin moves
  rules/recipe-metadata.md             # recipe header layout — read before a new .bb
  rules/comment-style.md               # comment rules — read before a recipe/config comment
  rules/cross-compilation.md           # aarch64-edgeai-linux SDK notes
  settings.json                        # registers the hook below (Claude Code only)
  hooks/no-parallel-bitbake.py         # refuses a second bitbake/kas/make build or parse
  agents/build-watcher.md              # read-only build-run reporter (Claude Code only)
  agents/yocto-rules-reviewer.md       # read-only diff review against rules/ (Claude Code only)
meta-edge-distro/                      # brand identity + DISTRO=edge-ai
  conf/distro/edge-ai.conf
  recipes-core/psplash/                # EDGE AI OS brand splash
meta-edge-bsp/                         # image scaffolding + board patches
  conf/machine/include/edge-board-*.inc  # per-board facts
  recipes-core/images/edge-image-*.bb
  recipes-support/edge-systemd-presets/
  dynamic-layers/<collection>/         # vendor-targeting recipes/bbappends, parsed
                                       #   only when that layer is composed
                                       #   (meta-rz-{bsp,distro}, raspberrypi)
.kas/                                  # kas-managed upstream layers (meta-renesas,
                                       #   bitbake, openembedded-core, …); gitignored.
                                       #   See docs/adr/0002-layer-hosting.md.
build/                                 # bitbake output (gitignored)
```

## Conventions

- **Public-repo discipline** — committed files (recipes, kas, scripts)
  reference only repo-relative build paths or public `docs/`; never
  `.claude/` or agent-tooling paths, absolute `/home/<user>/...` paths,
  board IPs, or home-lab topology. Personal config goes in `kas/local.yml`
  (gitignored).
- **Custom distro `edge-ai`, not Poky** — defined in
  `meta-edge-distro/conf/distro/edge-ai.conf`. SBOM (SPDX 3.0) and CVE
  check are wired into the distro from day one.
- **Per-board vendor BSP and kernel (ADR-0011)** — RZ/V2L: `meta-renesas`
  provides the machine configs and the `linux-renesas` kernel recipe, which
  fetches `github.com/renesas-rz/rz_linux-cip.git` (CIP base + Renesas RZ
  enablement on top); TF-A and U-Boot follow the Renesas CIP forks.
  Raspberry Pi 5: `meta-raspberrypi` provides the machine conf and firmware
  boot files; the kernel is this repo's `linux-edge-mainline` (kernel.org
  stable 6.18, `dynamic-layers/raspberrypi/`), U-Boot is oe-core's.
  Kernel policy shared by every board lives in
  `recipes-kernel/linux/edge-kernel-policy.inc`, including the KSPP gate
  every prod kernel build runs against the board's baseline in
  `files/khc/` (`docs/security/kernel-config/README.md`).
- **Layer ownership** — `meta-edge-distro` owns brand + distro identity;
  `meta-edge-bsp` owns image recipes and board-level patches. Do not
  mix.

## Commit style

Conventional Commits — `<type>(<scope>): <subject>`. Enforced at the
`commit-msg` stage by `.pre-commit-config.yaml`; the why is in
[ADR-0007](docs/adr/0007-conventional-commits-changelog.md) (commits feed
automated release notes via git-cliff on `v`-semver tags).

Types: `feat`, `fix`, `docs`, `build`, `chore`, `ci`, `style`, `perf`,
`refactor`, `test`, `revert`.

Scopes follow the layer/area and may contain `/` and `-`: `build`,
`distro`, `bsp`, `bsp/tfa`, `bsp/uboot`, `bsp/optee`, `bsp/kernel`,
`bsp/init`, `bsp/security`, `bsp/userland`, `bsp/network`, `rauc-ota`,
`packagegroups`, `images`. (`+` is not accepted by the commit-msg hook's
default scope charset — use `-`.)

Subject: imperative mood ("add X", not "added X" or "adds X"), no
trailing period, ≤72 chars including the `<type>(<scope>): ` prefix.

`chore`, `ci`, and `style` are excluded from the generated release notes
(they are release-noise); the rest are grouped by type. A genuinely
unconventional commit needs a conscious `git commit --no-verify`.

## Git hooks

Two gates, both driven by `.pre-commit-config.yaml`:

```bash
make hooks     # run once after cloning; idempotent
```

- **commit stage** — `scripts/hooks/forbid-private-keys.sh` refuses
  staged private-key material and anything under `keys/`.
  Defense-in-depth over `.gitignore`, which does not stop `git add -f`
  or a `git mv` of an already-tracked file into `keys/` (rename
  detection classifies that as `R` and the file stays tracked). The
  content check matches the PEM armor line, not the bare words, so
  security docs that discuss key handling commit normally.
- **commit-msg stage** — Conventional Commit subject, per §"Commit
  style" above, and `scripts/hooks/check-commit-trailers.sh`: no AI
  `Co-Authored-By:`, no `scratch/` or `/home/<user>/` paths in the
  message (§"AI attribution"). `make check` runs the same check over
  the branch's commits.

pre-commit installs into `.git/hooks`, which is per-clone and untracked:
a fresh clone has **both gates silently disabled** until `make hooks`
runs. Note that `pre-commit install --hook-type commit-msg` alone
installs only the subject check — `make hooks` passes both stages.

Neither hook is a security control on its own; a DER-encoded key under
an innocuous name passes the content check, and the `keys/` path guard
is the real control there. CI and review still matter.

### AI attribution

Agents write the changes and the maintainer authors and answers for them
(§"What this repo is"). That is stated once, here, not per commit.

- **No `Assisted-by:` trailer** on new commits or newly written patches.
  Existing commits and patches keep theirs: history is not rewritten, and a
  patch-header edit forces a rebuild of the recipe.
- **No `Co-Authored-By:` for an AI tool**, in commits or PR bodies, and no
  generated-with footer in PR bodies. This overrides tool defaults that emit
  them. The commit-msg hook refuses an AI co-author; a non-AI bot such as
  Dependabot passes.
- When how a change was made matters to its review, the PR description says
  so.

The trailer came from the Linux kernel, which removed it from its docs in
commit 1e035297ffda ("docs: remove Assisted-by references"): a per-change
tag that many contributors leave off gives no reliable signal.

**Patches are not commits.** Shipped `.patch` files carry their own headers
and their own rules, including the hard rule that a `Backport` patch's header
is never touched. See `.claude/rules/yocto-patterns.md` §"Patch headers".

Mechanics for Claude Code sessions are in `CLAUDE.md`.

Do not run git commands without operator confirmation (see `CLAUDE.md`).

## Validating behaviour changes

A green build and an approving review are not evidence. Both are produced by
reasoning over the same artifact with the same blind spots — an agent reviewing an
agent's change converges on *plausible*, not *correct*. Before claiming a change is
right, produce a check whose answer comes from something other than a model.

Applies to any change that decides something about real inputs:

- matching, filtering or classifying logic — parsers, regexes, globs, version
  comparisons, dedupe/merge rules
- security metadata that suppresses findings — `CVE_STATUS` dispositions, VEX
  claims, exclusion lists. These fail **silently**: a wrong entry removes a CVE from
  the report instead of turning something red, and downstream tooling that trusts
  `CVE_STATUS` inherits the mistake. This distro wires SBOM (SPDX 3.0) and CVE check
  in from day one, so those artifacts are shipped output, not a side report.
- anything whose failure mode is "the output looks fine but something is missing"

Ranked by what the evidence is worth:

1. **Differential run** — keep the old behaviour beside the new, run both over real
   data, diff the outputs. Every disagreement is a change you must be able to
   explain. Check **both** directions: what stopped matching, and what started.
2. **Per-claim verification against an independent source** — for metadata
   dispositions, check each claim (shipped version vs fixed boundary, product
   mismatch) against upstream CVE data, *not* against the scanner that produced the
   finding.
3. **On-target validation** — for runtime behaviour the board is the oracle.
4. A build, lint run, or test suite — necessary, but only covers what someone
   already thought of.

What makes it actually work:

- **Classify the whole delta, not the top N.** The tail is where the wrong ones hide.
- **Isolate the variable** — set local changes aside and re-measure the raw baseline
  first, so the delta is attributable to the change and not to image drift.
- **State which axis is clean** when the underlying data drifts, rather than quoting
  a total that mixes signal with feed noise.
- **Keep the commands re-runnable** and logged next to the work, so the numbers can
  be reproduced instead of believed.
- **Put the result in the commit body** — what was run, what it showed. When a claim
  could not be verified, say so plainly. "Unverified" is a valid state; a confident
  sentence covering for one is not.

## Working economically

- **Evidence and continuity:** for multi-phase work, pickup or an explicit pause,
  read `.claude/skills/agent-evidence/SKILL.md` (Codex and Claude Code alike).
  Save long reviews/findings in the ignored scratch directory and link them
  from chat, unless the user specifies another output. Shared format:
  `docs/dev/agent-workflow.md`.
- **Operator corrections:** use `.claude/skills/correction-loop/SKILL.md` to
  turn demonstrated mistakes into scoped checks; do not expand the task or
  treat proposed controls as implemented enforcement.
- Inspect narrowly before scanning broadly — a recipe name or
  `bitbake-getvar` beats a repo-wide grep.
- Validate progressively: `make parse` → the affected recipe's task →
  image build. Don't launch a full image build to test a parse-level
  change.
- On build failure, extract the **first causal error** from the task
  log and cite log files by path (`build/<BOARD>/tmp/work/.../temp/log.do_*`);
  don't paste whole BitBake logs into the conversation.
- Don't re-run an equivalent failing command hoping for a different
  result — change one variable per retry.
- No speculative adjacent refactors; keep the diff scoped to the
  request.
- Subagents and isolated worktrees only when parallelism or build
  pollution justifies the cost (Claude: `yocto-worktree` skill).
- **Long-running builds (>~10 min): launch detached, never via the
  agent harness's background-process mechanism.** A harness-spawned
  background process stays a child of the agent's tool runner and dies
  with it — the build gets SIGTERM'd mid-task (`make` exits 241 with no
  bitbake `ERROR:` lines, which reads like a mystery failure). Instead,
  launch it through the build launcher
  ([docs/dev/agent-builds.md](docs/dev/agent-builds.md)):

  ```bash
  . scripts/env.sh && python3 scripts/agent-build/agent-build.py start <topic> -- <target> BOARD=<board>
  ```

  It runs make in its own tmux session, records the command, board and
  source commit in `build/agent-runs/<run-id>/run.json` and make's exit
  code in `result.json`, and gives the operator a read-only `tmux
  attach` view. Report the attach command right away, then follow it with
  `agent-build.py status` or `agent-build.py wait --timeout N` (exit 0
  succeeded, 1 failed, 2 interrupted/unknown, 3 still running), never with
  plain `tmux`, which talks to another server and makes a running build
  look finished. A killed `wait` is just rerun; the build survives. For builds that matter, prefer handing the operator
  the same command to run in their own shell. `setsid nohup make …` is
  the fallback where tmux is missing. A killed build is recoverable
  either way (bitbake resumes from sstate).
- Stop at the requested milestone; report remaining work instead of
  continuing unprompted.

## Branch strategy

Work lands on short-lived branches off a protected, linear `main`,
merged via PR — the PR is the review gate.

**Before opening a PR, run `make check`** and paste its final `RESULT:` line into
the PR body. A failing check is fixed before the PR opens, not after. Changes that
can break parsing or a build also get `make ci` on the build host
([docs/dev/ci.md](docs/dev/ci.md)).

Branch naming: `<scope>/<topic>` for single-scope work (scope from the
§"Commit style" set, e.g. `bsp/init/persistence-refactor`), or
`<type>/<topic>` when a change spans several scopes (e.g.
`feat/drpai-integration`).

**Releases.** Annotated tags `vMAJOR.MINOR.PATCH`; the tag,
`DISTRO_VERSION`, and the RAUC bundle version must agree (asserted at
bundle-build time).

**Worktrees are not branches.** The `git worktree` pattern in
`CLAUDE.md` is an ephemeral concurrency tool (avoiding `.kas/` /
`build/` races between parallel agents), not a workflow tier.

Backport branches (fixing a deployed `vX.Y` while `main` advances) are
deferred until the first release needs them.

## Where detailed guidance lives

| Task | Read |
|---|---|
| Wrynose features, failure triage, patch headers, sstate traps, pin moves | `.claude/rules/yocto-patterns.md` |
| Authoring a new recipe (header layout, metadata) | `.claude/rules/recipe-metadata.md` |
| Comments in recipes / kas / scripts | `.claude/rules/comment-style.md` |
| Prose in `docs/` and `README.md` (what may and may not be written) | `.claude/rules/docs-style.md` |
| Cross-compiling apps outside bitbake | `.claude/rules/cross-compilation.md` |
| Settled architecture decisions | `docs/adr/README.md` (index) |
| Layer compatibility: what `yocto-check-layer` checks and where the layers deliberately deviate | `docs/dev/layer-compatibility.md` |
| Vulnerability handling — reachability ladder, fix choice, release gate | `docs/security/VULN-HANDLING.md`, ADR-0013 |
| Security docs — SBOM/CVE triage, SELinux, U-Boot hardening, kernel-config gate, vuln mgmt | `docs/security/README.md` (index) |
| CI — `make check` before every PR, `make ci` on the build host, release notes | `docs/dev/ci.md` |
| Launching and watching long builds (agent-build launcher) | `docs/dev/agent-builds.md` |
| Evidence trail, session pickup/pause, correcting agent mistakes | `docs/dev/agent-workflow.md` |
| OTA updates + rollback testing | `docs/dev/ota-updates.md`, `docs/dev/ota-rollback-test-plan.md` |
| Bootchain update (per board) | `docs/dev/bootchain/README.md`, ADR-0014 |
| Netboot dev workflow (per board) | `docs/dev/netboot/README.md` |
| eMMC boot target + provisioning (per board) | `docs/dev/emmc/README.md` |
| Flashing a wic to SD/USB (bmaptool vs dd, reused-card env trap) | `docs/dev/flashing-media.md` |
| JTAG kernel debugging | `docs/dev/jtag-kernel-debugging.md` |
| Containers on-target (podman, Quadlet) | `docs/dev/podman.md`, `docs/dev/quadlet.md` |
| DRP-AI (port, compile models, benchmark) | `docs/drp-ai/README.md` |
| Board wiring status (wired vs. slot-available) | `.claude/references/board-catalogue.md` |
