# CI

The checks run locally, before a pull request, not on GitHub afterwards. The
only GitHub workflow publishes release notes.

| What | Where | When |
|---|---|---|
| `make check` | any checkout, seconds, no kas | before every pull request; the RESULT line goes in the PR body |
| `make ci` | the build host (layer and sstate caches) | a change that can break parsing, a composition or a build |
| `make preflight` | the build host, in the checkout being built | before an image or bundle build |
| `.github/workflows/release-notes.yml` | GitHub | `v*` tag push: git-cliff notes → GitHub Release |

Action versions are SHA-pinned and bumped monthly by Dependabot
(`.github/dependabot.yml`). Pre-commit (`make hooks`) refuses staged private
keys, non-conventional commit subjects and commit messages that fail the
trailer and leak check at commit time.

## `make check`

`scripts/ci/check.sh`, against `origin/main` (`CHECK_BASE=` to change it):

- repository invariants (`scripts/ci/repo-lint.sh`): wrynose override syntax,
  `Upstream-Status` on every patch, no agent paths, host home paths or key
  material in shipped files, no tracked archives or prebuilt objects, relative
  doc links resolve, required recipe header fields (SUMMARY of at most 80
  characters, DESCRIPTION of at most 3 lines, HOMEPAGE, SECTION, LICENSE,
  LIC_FILES_CHKSUM except for CLOSED, image and bundle recipes, no BUGTRACKER
  pointing at this repository), and every new commit message passing
  `scripts/hooks/check-commit-trailers.sh`: an `Assisted-by: <tool>:<model-id>`
  trailer, no AI `Co-Authored-By:`, no `scratch/` or `/home/<user>/` paths
- the private-key guard over all tracked files
- shellcheck at warning level on every shell script
- the ModelPack unit tests, the systemd-boot RAUC backend selftest, and the
  commit trailer check and preflight mapping selftests
- the serial-console tee and VENTUNO Q flash tool selftests, only when the tool
  or its selftest changed (tens of seconds each; `CHECK_ALL=1` forces them)

## `make preflight`

`scripts/ci/preflight.py` maps the changed paths (everything since the merge base
with `origin/main`: commits, uncommitted and untracked files;
or `--base REF`, or `--paths`) to the cheapest check that exercises them, for
one board:

```bash
make preflight PREFLIGHT_ARGS=--plan BOARD=rzv2l   # print the plan only
make preflight BOARD=rzv2l                         # host tier: scripts/ci/check.sh
make preflight BOARD=rzv2l PREFLIGHT_ARGS=--bitbake
```

The BitBake tier runs `do_patch` on the touched recipes (a deleted bbappend
counts for its recipe, and a shared `files/` directory counts for the recipes
that add it through `${EDGE_BSP_LAYERDIR}`), kernel `do_configure` for kernel
paths, the KSPP gate (`make kernel-hardening-check`) for fragments, the kernel
policy and KHC baselines on a board that has a baseline, and otherwise a parse for metadata and for kas files
in the board's default chain. It goes through
`make bitbake-task BB_TASK="<recipe…> -c <task>"`.

A path the board's run does not exercise is listed as not covered, with the
reason: another board's dynamic layer, board include or KHC baseline, a kas
fragment that only a make flag composes, a kernel fragment gated by a flag, or
a shared `files/` directory applied by another board's recipe. A recipe whose
`COMPATIBLE_MACHINE` lists only other boards' machines is left out with a note;
a value naming SoC families or overrides is noted and left to BitBake
(`--exclude-recipe <pn>` drops one that the board skips). Image and bundle
recipes get a parse only: their `do_unpack` depends on a built image. A class is
read only where a recipe inherits it, so a parse does not prove a class that
the board never uses.

The tier refuses (exit 3) while any board's `bitbake.lock` or
`.agent-build.lock` is held (one build per host), and when `kas/local.yml` is
missing (`--allow-cold` overrides). A pass shows that patches apply, `file://`
sources exist and the metadata parses, not that the image works.

## `make ci`

`scripts/ci/local-check.sh` checks a commit (default `origin/main`) out as a
detached worktree under `/var/tmp/edge-ci/`, seeded with `kas/ci-local.yml` or
`kas/local.yml` and the host's `keys/`, and posts one GitHub commit status per
stage. One bitbake runs per host; the script refuses to start beside another
build.

```bash
make ci                                  # origin/main, quick parse matrix
make ci CI_ARGS='--ref pr/16'            # a pull request head
make ci CI_ARGS='--matrix full'          # + every optional capability fragment
make ci CI_ARGS='--build rzv2l'          # + edge-image-dev and edge-bundle for one board
make ci CI_ARGS='--khc'                  # + kernel-hardening gate, rzv2l and raspberrypi5
make ci CI_ARGS='--no-status'            # run without posting
```

| Status context | Stage |
|---|---|
| `yocto/pins` | every composed repo carries a `commit:` pin that `kas dump --resolve-refs` agrees with, for every board |
| `yocto/parse` | `make parse` per matrix cell |
| `yocto/image-<board>`, `yocto/bundle-<board>` | `make dev` and `make bundle` (`--build`; 30–50 GB free disk) |
| `yocto/khc-<board>` | prod `.config` exported (configure only), gated against the board's baseline, and equal to the committed snapshot (`--khc`; needs `kernel-hardening-checker` on `PATH`; [kernel-config](../security/kernel-config/README.md)) |

`quick` parses every board at the dev tier, and rzv2l and raspberrypi5 at the
prod tier (VENTUNO Q has no prod cell: ADR-0016 §2). `full` adds `TPM=1`,
`JTAG=1`, `BPF=1`, `NETBOOT=1`, `OPTEE_EXAMPLES=1`, `SBOM_TUNE=1`,
`LAYOUT=emmc`, `ACCEL=none` and a parse with no host overlay, for rzv2l and
raspberrypi5: optional fragments that nothing composes by default are the ones
that stop working unnoticed.

Logs land in `<workdir>/logs/<sha7>/`, `--build` artefacts in
`<workdir>/artifacts/<sha7>/<board>/`, signed with the host's dev keys. The
checker is the `local-check.sh` of the checkout `make ci` runs from; the tree
under check is the requested commit. Statuses are self-reported and are not
required checks on `main`.
