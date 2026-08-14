# AGENTS.md

Canonical orientation for AI coding agents working in this repo.
Agent-agnostic: Claude Code, Codex, Cursor, Copilot, etc. Claude-
specific extras (skills, MCP servers) live in `CLAUDE.md`.

## What this repo is

See [README.md](README.md) for the platform summary. Short version:
KAS-driven Yocto 6.0 (wrynose) build, custom `edge-ai` distro, Renesas
vendor BSP (CIP-aligned `linux-renesas` kernel; preserves the SLTS
intent of ADR-0001), RZ/V2L SMARC EVK first board.

## Build commands

Always prefer `make` over raw `kas`/`bitbake` — the wrapper resolves
the composition for you.

```bash
make help                 # authoritative target catalogue — check before raw bitbake
make base                 # build edge-image-base (the v0 wired tier)
make dev | prod           # dev / hardened-prod image tiers
make bundle               # RAUC .raucb for OTA install
make parse                # bitbake -p (parse-only sanity — cheapest validation)
make layers               # bitbake-layers show-layers
make shell                # interactive KAS shell
make clean-lock           # remove a stale build/bitbake.lock
```

Capability toggles are **make flags, not shell environment**:

```bash
make dev VIRT=1                  # + meta-virtualization (Podman/runc/crun)
make dev TPM=1                   # + meta-secure-core (TPM2 + IMA/EVM)
make dev JTAG=1 BPF=1            # flags compose freely
make dev EDGE_BOOT_TARGET=emmc   # GPT + systemd-repart eMMC layout
```

Full flag catalogue: `make help`. A bare `EDGE_*=1` exported in the
shell is **silently dropped** — kas and bitbake filter the inherited
environment (`BB_ENV_PASSTHROUGH_ADDITIONS`), so every toggle must go
through the Makefile, which maps it to a kas capability fragment or a
whitelisted env var.

## KAS composition

```
kas/base.yml         <- distro + layer wiring + kernel choice (CIP-aligned linux-renesas 6.12)
kas/machines/*.yml   <- board pick (e.g. rzv2l.yml)
kas/local.yml        <- personal overlay (paths, parallelism); gitignored
kas/local.yml.example <- template
```

Compose with `:`:

```
kas build kas/base.yml:kas/machines/rzv2l.yml
# Image tier is picked via the bitbake target name (edge-image-base /
# edge-image-dev), not a kas overlay; the make wrapper handles this.
```

The Makefile reads `kas/local.yml` first if present; otherwise it
composes the explicit chain.

### Standalone `kas` invocations — source the env first

The Makefile exports `KAS_WORK_DIR`/`KAS_BUILD_DIR`/`KAS_REPO_REF_DIR`
only to its own sub-processes. A bare `kas shell …` in any other shell
falls back to kas' default `KAS_WORK_DIR = CWD` and **re-clones the
entire upstream layer stack into the repo root**. When a raw kas call
is unavoidable (e.g. `bitbake -e` variable inspection), source the env
in the same command:

```bash
. scripts/env.sh && kas shell -c 'bitbake-getvar -r u-boot SRC_URI' kas/local.yml
```

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
docs/
  adr/                                 # Architecture Decision Records — read
                                       #   before re-deriving settled choices.
                                       #   0001 = kernel base (linux-cip 6.12 SLTS).
.claude/
  context/bsp-workflow.md              # layer ownership + workflow contract
  references/board-catalogue.md        # boards wired vs. slot-available
  rules/yocto-patterns.md              # wrynose syntax + SBOM/CVE wiring
  rules/recipe-metadata.md             # recipe header layout — read before a new .bb
  rules/comment-style.md               # comment rules — read before a recipe/config comment
  rules/cross-compilation.md           # aarch64-edgeai-linux SDK notes
meta-edge-distro/                      # brand identity + DISTRO=edge-ai
  conf/distro/edge-ai.conf
  recipes-core/psplash/                # EDGE AI OS brand splash
meta-edge-bsp/                         # image scaffolding + board patches
  recipes-core/images/edge-image-*.bb
  recipes-support/edge-systemd-presets/
.kas/                                  # kas-managed upstream layers (meta-renesas,
                                       #   bitbake, openembedded-core, …); gitignored.
                                       #   See docs/adr/0002-layer-hosting.md.
build/                                 # bitbake output (gitignored)
```

## Conventions

- **Wrynose 6.0 override syntax** — `RDEPENDS:${PN}`, `do_install:append()`,
  `SRC_URI:append:rzv2l`. Never the deprecated underscore form. See
  `.claude/rules/yocto-patterns.md`.
- **Public-repo discipline** — committed files (recipes, kas, scripts)
  reference only repo-relative build paths or public `docs/`; never
  `.claude/` or agent-tooling paths, absolute `/home/<user>/...` paths,
  board IPs, or home-lab topology. Personal config goes in `kas/local.yml`
  (gitignored).
- **Custom distro `edge-ai`, not Poky** — defined in
  `meta-edge-distro/conf/distro/edge-ai.conf`. SBOM (SPDX 3.0) and CVE
  check are wired into the distro from day one.
- **Renesas vendor BSP, CIP-aligned** — `meta-renesas` provides the
  machine configs and the `linux-renesas` kernel recipe, which fetches
  `github.com/renesas-rz/rz_linux-cip.git` (CIP base + Renesas RZ
  enablement on top).
  TF-A and U-Boot follow the Renesas CIP forks.
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
  style" above.

pre-commit installs into `.git/hooks`, which is per-clone and untracked:
a fresh clone has **both gates silently disabled** until `make hooks`
runs. Note that `pre-commit install --hook-type commit-msg` alone
installs only the subject check — `make hooks` passes both stages.

Neither hook is a security control on its own; a DER-encoded key under
an innocuous name passes the content check, and the `keys/` path guard
is the real control there. CI and review still matter.

### AI attribution

Every commit an agent contributed to ends with an `Assisted-by:` trailer naming
the tool and the **exact model that did the work**:

```
Assisted-by: <tool>:<model-id>
```

Tool names in use: `claude-code`, `codex`, `kiro`. The model id half is
deliberately shown as a placeholder here and nowhere spelled out — see the first
rule below.

- **Never copy a model id out of this file, `CLAUDE.md`, or a past commit.**
  State the model the session is actually running as. A doc-pinned model string
  goes stale the moment the next release ships, and every agent that copies it
  writes a trailer that is quietly false.
- **One trailer per model that touched the change, in the order they touched
  it.** If Sonnet drafted and Opus later reviewed and amended, both lines stay.
  That is the whole point: a later reader — human or model — can see which model
  produced the original reasoning and which one revised it.
- **Never drop an earlier agent's trailer when amending.** The trailer records
  participation, not the largest share.
- Attribution is not certification. The operator remains the commit author and
  is responsible for having reviewed what the agent produced.

**Patches are not commits.** Shipped `.patch` files carry their own headers
and their own rules — including the hard rule that a `Backport` patch's header
is never touched. See `.claude/rules/yocto-patterns.md` §"AI attribution in
patch headers" before adding a trailer to anything under `files/`.

**Do not add `Co-Authored-By:` for an AI tool** — not in commits, not in PR
bodies. This overrides tool defaults that emit one (Claude Code's
generated-with footer); drop those lines. `Assisted-by:` already records the
same participation and records it better: it names the exact tool and model,
one line per model in the order they touched the change. `Co-Authored-By:`
asserts conventional authorship by something that cannot hold it, and
duplicates a fact the line above states precisely. One label, deliberately.

Applies to **new** commits from 2026-08-12 onward. Existing history keeps
whatever it carries — do not retrofit, amend or rewrite past commits to
match. A mixed history is honest; a rewritten one destroys the record the
trailer exists to provide.

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

- Inspect narrowly before scanning broadly — a recipe name or
  `bitbake-getvar` beats a repo-wide grep.
- Validate progressively: `make parse` → the affected recipe's task →
  image build. Don't launch a full image build to test a parse-level
  change.
- On build failure, extract the **first causal error** from the task
  log and cite log files by path (`build/tmp/work/.../temp/log.do_*`);
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
  from an ordinary foreground shell call:

  ```bash
  setsid nohup make <target> > scratch/<topic>.log 2>&1 &
  ```

  `setsid` gives the job its own session; once the launching shell
  exits it reparents to the init/user manager and nothing in the
  agent's process tree can signal it. Watch progress with a
  **separate** poller that only reads the log file — decouple the
  watcher from the work, so a killed poller is just re-armed while the
  build survives. For builds that matter, prefer handing the operator
  the one-liner to run in their own shell. A killed build is
  recoverable either way (bitbake resumes from sstate), but the
  detached form avoids the wasted hours and the misleading failure
  mode.
- Stop at the requested milestone; report remaining work instead of
  continuing unprompted.

## Branch strategy

Work lands on short-lived branches off a protected, linear `main`,
merged via PR — the PR is the review and CI gate.

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
| Yocto syntax, failure triage, patch headers, sstate traps | `.claude/rules/yocto-patterns.md` |
| Authoring a new recipe (header layout, metadata) | `.claude/rules/recipe-metadata.md` |
| Comments in recipes / kas / scripts | `.claude/rules/comment-style.md` |
| Cross-compiling apps outside bitbake | `.claude/rules/cross-compilation.md` |
| Settled architecture decisions | `docs/adr/README.md` (index) |
| Security docs — SBOM/CVE triage, SELinux, U-Boot hardening, vuln mgmt | `docs/security/README.md` (index) |
| OTA updates + rollback testing | `docs/dev/ota-updates.md`, `docs/dev/ota-rollback-test-plan.md` |
| Netboot dev workflow | `docs/dev/netboot-setup.md` |
| eMMC provisioning | `docs/dev/emmc-provisioning.md` |
| JTAG kernel debugging | `docs/dev/jtag-kernel-debugging.md` |
| Containers on-target (podman, Quadlet) | `docs/dev/podman.md`, `docs/dev/quadlet.md` |
| DRP-AI (port, compile models, benchmark) | `docs/drp-ai/README.md` |
| Board wiring status (wired vs. slot-available) | `.claude/references/board-catalogue.md` |
