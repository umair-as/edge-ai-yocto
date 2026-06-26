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
make help                 # list targets
make base                 # build edge-image-base (the v0 wired tier)
make parse                # bitbake -p (parse-only sanity)
make layers               # bitbake-layers show-layers
make shell                # interactive KAS shell
make clean-lock           # remove a stale build/bitbake.lock
```

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

AI-assisted commits end with a generated-with footer and a `Co-Authored-By:`
trailer — Claude Code's exact footer is in `CLAUDE.md`.

Do not run git commands without operator confirmation (see `CLAUDE.md`).

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
