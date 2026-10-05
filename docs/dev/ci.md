# CI

Two halves. GitHub-hosted runners do the text-only checks on every pull
request. The Yocto checks run on a build host with the layer and sstate
caches, when the operator runs them, and report back as commit statuses.

## Hosted (automatic)

| Workflow | Checks | Trigger |
|---|---|---|
| `.github/workflows/lint.yml` | `scripts/ci/repo-lint.sh` (override syntax, `Upstream-Status`, leaked host paths and key material, doc links, commit trailers), the ModelPack unit tests, the staged-private-key guard | every pull request, push to `main` |
| `.github/workflows/release-notes.yml` | git-cliff release notes → GitHub Release | `v*` tag push |

Action versions are SHA-pinned and bumped by Dependabot (`.github/dependabot.yml`).

## Yocto checks (operator-run)

Two ways to run the same check, both started by the operator:

```bash
# From GitHub: start the runner on the build host, then dispatch.
~/actions-runner/run.sh --once                       # takes one job, then exits
gh workflow run yocto.yml --ref main -f matrix=quick # or Actions → "Yocto check" → Run workflow

# Without GitHub Actions: run locally, report as commit statuses.
make ci                                  # origin/main, quick parse matrix
make ci CI_ARGS='--ref pr/16'            # a pull request head
make ci CI_ARGS='--matrix full'          # every optional capability fragment
make ci CI_ARGS='--build rzv2l'          # + edge-image-dev and edge-bundle for one board
make ci CI_ARGS='--no-status'            # run without posting
```

### `.github/workflows/yocto.yml` — dispatch only

`workflow_dispatch` is the only trigger. The repo is public, so a self-hosted
runner must never pick up a `pull_request`, `push` or `schedule` job: anyone
able to cause such an event would be running code on the build host. The job
has one step, `make ci` in the operator's checkout (`EDGE_REPO` from the
runner's `.env`), with `--no-status` because the workflow run is the check.
The script's one-line-per-cell output is copied into the run summary; the full
logs stay on the host. Run logs are public and carry no host paths.

The runner (`~/actions-runner`, label `yocto-host`) is registered to this
repository and runs as the operator's user, so it sees the same `kas/local.yml`,
caches and `keys/` as an interactive build. It is not a service: start it
before dispatching. `run.sh --once` exits after one job; plain `run.sh` keeps
listening until stopped. The runner marks `--once` as deprecated in favour of
`--ephemeral`, which de-registers after every job and needs a new registration
token each time — a poor fit for a hand-started runner, so `--once` stays until
it is removed. A job dispatched while the runner is offline queues and fails
after 24 hours. The runner's `.env` carries
`EDGE_REPO` and `KAS_REPO_REF_DIR`; its `.path` must include the directory that
holds `kas`.

### `scripts/ci/local-check.sh`

The tree under check is the requested commit; the checker itself — this
script and the `Makefile` `ci` target — is the version checked out in the
repository `make ci` runs from. A change to the checker is exercised once that
checkout carries it.

The script checks the commit out as a detached git worktree
under `/var/tmp/edge-ci/` (`EDGE_CI_WORKDIR`), so the committed tree is what
gets checked, never the working tree. The worktree is seeded with
`kas/ci-local.yml` when present, else `kas/local.yml`, plus a link to the
host's `keys/` (the RAUC CA certificate is a parse-time `SRC_URI` input of
`rauc-conf`; run `scripts/rauc-init-certs.sh` once per host), and removed at
exit (`--keep` retains it). One bitbake runs on a host at a time; the script refuses
to start while another build is running.

| Status context | Stage |
|---|---|
| `yocto/pins` | every composed repo carries a `commit:` pin and `kas dump --resolve-refs` agrees with it, for both boards |
| `yocto/parse` | `make parse` for each cell of the matrix |
| `yocto/image-<board>` | `make dev BOARD=<board>` (`--build`) |
| `yocto/bundle-<board>` | `make bundle BOARD=<board>` (`--build`) |

Matrix cells are one uncached parse each (about two minutes on an 8-core host):

- `quick`: both boards × `EDGE_PROFILE=dev|prod` — 4 cells.
- `full`: `quick` plus, per board at the dev tier, `TPM=1`, `JTAG=1`, `BPF=1`,
  `NETBOOT=1`, `OPTEE_EXAMPLES=1`, `SBOM_TUNE=1`, `EDGE_BOOT_TARGET=emmc`,
  `ACCEL=none`, and one parse of the public composition with no host overlay
  — 21 cells. Optional fragments that nothing composes by default are the
  ones that rot unnoticed; this is where they are exercised.

Logs land in `<workdir>/logs/<sha7>/<cell>.log`; `--build` artefacts
(`.raucb`, `.wic*`, manifest, FIT image, sstate and task summaries) in
`<workdir>/artifacts/<sha7>/<board>/`. Build artefacts are signed with the
host's `keys/dev/`, the same keys as an operator build, so a bundle from
`--build` is installable on a board that trusts them. A `--build` needs
roughly 30–50 GB of free disk while it runs.

When run directly, statuses are posted with the `gh` CLI's credentials to the
commit, where they show on the commit and in any open pull request for it. They
are self-reported from the build host. Neither they nor the dispatched workflow
are required checks on `main`.

Images carry `EDGE_BUILD_ID` from the build time, so two runs on the same
commit produce different images by design; the check asserts that the build
succeeds, not that it is bit-identical.
