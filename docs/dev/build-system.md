# Build system

`make` composes a kas stack and runs one command in it. `make help` lists the
targets, the capability flags and the settings; this page explains how the
pieces fit.

## Composition

```
kas/base.yml : kas/machines/<BOARD>.yml : <flag fragments> : kas/boot/<LAYOUT>.yml : kas/local.yml
```

- `kas/base.yml` holds the distro, the pinned layer set and the base
  `local.conf`. The machine fragment includes the board's BSP and accelerator.
- A capability flag `FLAG=1` adds one fragment; the flag table at the top of
  the Makefile maps each flag to its file, and `make help` prints each
  fragment's first comment line. Adding a flag is one table entry plus its
  fragment.
- `ACCEL=<name>` adds `kas/accel/<name>.yml` on top of the machine's own
  accelerator.
- `kas/local.yml` (gitignored, template `kas/local.yml.example`) is appended
  last when it exists. It carries host settings — cache paths, parallelism,
  credentials — and never selects the board.

Layer clones live in `.kas/` (`KAS_WORK_DIR`). `KAS_REPO_REF_DIR` points at a
host-local git-alternates cache scoped per release line
(`/mnt/yocto-nvme/layers-wrynose`); kas copies objects from it instead of
fetching, and falls back to full clones when it is absent. Pins are enforced
either way. See ADR-0002.

## Build directories

Each board builds in `build/<BOARD>/`. All boards share `DL_DIR` and
`SSTATE_DIR`: sstate keys on task signatures, not paths, so separate trees
cost no cache. A tree's `TMPDIR` cannot move (`sanity.bbclass` refuses a
relocated `TMPDIR`).

The Makefile sets `KAS_BUILD_DIR` with `override`: a value inherited from the
shell (`scripts/env.sh`, or a shell that last built another board) never
selects the tree.

## Build settings

`EDGE_PROFILE`, `BUNDLE_IMAGE_NAME` and `EDGE_BUNDLE_SBOM_CVE` are read at
bitbake startup, before any conf file is parsed, so they have to arrive in
the environment. `kas/base.yml` lists them under `env:`; kas forwards each
one to bitbake and adds it to `BB_ENV_PASSTHROUGH_ADDITIONS`. A `null` entry
is forwarded only when set, so the conf default (`?=`) applies otherwise.

Each make target sets the values it needs on its kas command. The Makefile
`unexport`s the three names, so a value exported in the calling shell does
not reach the build: `make prod` builds the prod tier whatever the shell
holds. Raw `kas shell` invocations (after `. scripts/env.sh`) do pass a value
from the shell, because kas reads its `env:` keys from the caller.

## On-disk layout

`LAYOUT=esd` (default; MBR, eSD/SD boot) or `LAYOUT=emmc` (GPT user area grown
by systemd-repart). Any layout other than `esd` is the fragment
`kas/boot/<layout>.yml`, which sets `EDGE_BOOT_TARGET`.

The layout a tree was last built for is stamped in
`build/<BOARD>/edge-layout`. Build targets reuse it when `LAYOUT` is not
given, so `make dev LAYOUT=emmc` followed by `make bundle` produces an eMMC
bundle. A build target given a `LAYOUT` different from the stamp refuses to
run; `LAYOUT_CHANGE=1` switches the tree. `make parse` ignores the stamp and
uses `LAYOUT` or `esd`, so parse checks do not depend on the tree. `make
info` prints the layout in effect.

## Bundles

`make bundle` builds `edge-bundle`, which depends on the image's
`do_image_complete`; a separate `make dev` first is not needed.
`IMAGE=dev|prod` selects the image and its tier together. `SBOM_CVE=1` adds
the image SBOM and CVE report to a dev bundle; prod bundles always carry it.

Bundle targets need the RAUC signing chain under `keys/dev/rauc/`
(`scripts/rauc-init-certs.sh`). Image builds need its recipient key when
bundle encryption is on (`EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION`, default `1`);
make prints a note when the key is missing and no composed kas file turns
encryption off.

## Maintenance targets

- `make clean-lock` removes `bitbake.lock` only when no server holds it.
  Removing a held lock leaves the server's flock on the unlinked inode, and
  the next bitbake starts a second server on the same `TMPDIR`.
- `make purge CONFIRM=1` removes `.kas/` and `build/`, i.e. every board's
  `TMPDIR`. It does not use `kas purge`, which on kas 4.8.2 also removes
  `KAS_REPO_REF_DIR`. Downloads, sstate and `kas/local.yml` are untouched.
- `make lock` writes `kas/base.lock.yml`, freezing floating branches to SHAs.
- `make cve ARGS='<subcommand> …'` runs `scripts/cve-monitor.py` on the host
  (no kas); its `--help` lists the subcommands and options.
