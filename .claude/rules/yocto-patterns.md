# Yocto patterns — wrynose 6.0

Rules that apply to recipe edits and kas wiring in this repo.

For the canonical header layout of a new `.bb` (SUMMARY, DESCRIPTION,
HOMEPAGE, SECTION, LICENSE, CVE_PRODUCT, UPSTREAM_CHECK_*, etc.) see
`recipe-metadata.md`. This file covers wrynose-specific syntax;
`recipe-metadata.md` covers what metadata to put in every recipe and why.

## BitBake failure triage

Validate progressively — `make parse` first, then the affected recipe's
task, then the image. Extract the first causal error from the task log;
don't paste whole build logs.

```bash
# Task log for a failing recipe
find build/tmp/work -path "*/<recipe>/*/temp/log.do_<task>" | head -1

# Variable inspection
make shell   # then, inside:
bitbake-getvar -r <recipe> <VAR>

# Who provides / who appends
bitbake-layers show-recipes <recipe>
bitbake-layers show-appends | grep -i <recipe>

# Re-run one task
bitbake <recipe> -c <task> -f
```

| Error | Likely cause |
|---|---|
| `Nothing PROVIDES` | Missing `DEPENDS`, or the layer isn't in the kas composition |
| `do_fetch failed` | Bad URI, no network, or wrong `SRCREV`. CVE-DB recipes are AUTOREV and need network on first fetch |
| `QA Issue: -dev contains` | Missing `RDEPENDS` or `FILES` entries |
| `multiple providers` | Need `PREFERRED_PROVIDER` in distro/machine conf |
| `do_patch failed` | Patch base doesn't match current `SRCREV` — regenerate, don't rebase hunks |
| `Missing Upstream-Status in patch` | `patch-status` QA gate; see "Patch headers" below |
| `virtual:devupstream:target:...:do_patch` | meta-arm `BBCLASSEXTEND` trap — see below |
| Packagegroup resolves as `noarch` | `PACKAGE_ARCH` set after `inherit packagegroup` — see below |
| `S`/unpack path errors | `S = "${WORKDIR}/git"` is gone — see "Source layout" below |
| Filesystems silently not built | `IMAGE_FSTYPES ?=` loses to oe-core's weak default — use `=` or `:append` |
| Taskhash / sstate mismatch | Usually a patch-header edit (see "Patch + sstate cascade") |

## Override syntax (colons, not underscores)

Wrynose uses the colon-based override syntax. The deprecated underscore
form was removed.

```bitbake
# Correct
RDEPENDS:${PN}        = "foo bar"
SRC_URI:append:rzv2l  = " file://board-fixup.patch"
do_install:append()   { ... }

# Wrong (rejected by the parser)
RDEPENDS_${PN}     = "..."
SRC_URI_append_rzv2l = " ..."
```

## DISTRO_FEATURES — wrynose split

`DISTRO_FEATURES_BACKFILL` and `DISTRO_FEATURES_BACKFILL_CONSIDERED`
are gone. Use:

- `DISTRO_FEATURES_DEFAULTS` — features the distro starts with
- `DISTRO_FEATURES_OPTED_OUT` — features removed from the auto-enabled set

Same split for `MACHINE_FEATURES_*`.

Five features became auto-enabled in 6.0 (`multiarch`, `opengl`,
`ptest`, `vulkan`, `wayland`). For the `edge` distro we keep `opengl`
and `wayland`; we opt out of the others (see `conf/distro/edge.conf`).

## SBOM + CVE

- SPDX 2.2 is gone. `INHERIT += "create-spdx"` auto-inherits the latest
  stable (3.0.1 at the wrynose pin).
- `cve-check.bbclass` is gone. Use `OE_FRAGMENTS += "yocto/sbom-cve-check"`.
- Fragment auto-adds `IMAGE_CLASSES:append = " sbom-cve-check"` and the
  `create-spdx` inherit. The explicit inherit in `edge.conf` is for
  visibility, not for function.
- The CVE-DB recipes (`sbom-cve-check-update-nvd-native`,
  `sbom-cve-check-update-cvelist-native`) use AUTOREV. The build host
  needs network at first fetch.

## U-Boot config

`UBOOT_CONFIG[foo]` flag syntax is gone. Use the variable suffix form:

```bitbake
UBOOT_CONFIG_BINARY       = "..."
UBOOT_CONFIG_IMAGE_FSTYPES = "..."
UBOOT_CONFIG_MAKE_OPTS    = "..."
```

We do not use this pattern in v0 (the Renesas vendor BSP `meta-renesas`
picks the U-Boot recipe directly). Check before adopting any
externally-authored U-Boot bbappend.

## pkgconfig

Recipes that call `pkg-config` must `inherit pkgconfig` explicitly —
no auto-export. The `pkgconfig` recipe is renamed to `pkgconf` for
RDEPENDS/DEPENDS references.

## Packagegroup PACKAGE_ARCH ordering

`packagegroup.bbclass` conditionally inherits `allarch` based on the
value of `PACKAGE_ARCH` at the moment its `inherit` line is parsed:

```bitbake
inherit ${@oe.utils.ifelse(d.getVar('PACKAGE_ARCH', True) == 'all', 'allarch', '')}
```

If a packagegroup recipe pulls machine-arch content via `RDEPENDS`
(`kernel-modules`, `libteec`, `libv4l`, …), it MUST set
`PACKAGE_ARCH = "${MACHINE_ARCH}"` **before** `inherit packagegroup`.
A post-inherit assignment is too late — `allarch` is already in the
class chain and the recipe ships as `noarch`, failing dependency
resolution at image-build time.

```bitbake
PACKAGE_ARCH = "${MACHINE_ARCH}"
inherit packagegroup
```

No inline comment in the recipe; the pattern is convention. Every
`packagegroup-edge-*.bb` in this repo follows it.

## Patch headers

Every `file://*.patch` in `SRC_URI` must declare `Upstream-Status:`.
`do_patch` enforces this via the `patch-status` QA check; a missing
header fails the build with `Missing Upstream-Status in patch ...
[patch-status]`. This is a build gate, not a style preference.

Canonical header (git format-patch convention):

```
From <40-char-sha> Mon Sep 17 00:00:00 2001
From: Author Name <author@example.invalid>
Date: <RFC2822 date>
Subject: [PATCH] <subsystem>: <imperative-mood one-line summary>

Upstream-Status: <value> [<short reason>]
Assisted-by: <tool>:<model-id>
Signed-off-by: Author Name <author@example.invalid>

<optional body — why the patch exists, links to bug trackers, etc.>
---
 <diffstat>

diff --git a/... b/...
```

Required: `From:`, `Date:`, `Subject:`, `Upstream-Status:`. Recommended:
`Signed-off-by:` when the patch could plausibly go upstream (DCO).
Optional for board-specific patches that will never be submitted.

### `Upstream-Status` vocabulary

| Value | When | Example reason |
|---|---|---|
| `Inappropriate [<reason>]` | Won't go upstream from this repo. Board/distro-specific. | `[board-specific configuration]` |
| `Pending` | Could go upstream; not submitted yet. | (no bracket needed) |
| `Submitted [<URL>]` | Sent upstream; awaiting decision. | `[patchwork.kernel.org/...]` |
| `Backport [<from-version-or-URL>]` | Cherry-picked from a later upstream tag. | `[v6.13-rc1, commit abc123]` |
| `Denied [<reason>]` | Rejected by upstream; carried locally with cost noted. | `[maintainer NACK: locking]` |
| `Accepted [<commit>]` | Merged upstream after we carried it. Transitional — drop on the next kernel/recipe bump that includes it. | `[v6.13, commit deadbeef]` |

Default for repo-local DTS patches:
`Inappropriate [board-specific configuration]` — matches the existing
pattern in `meta-edge-bsp/recipes-kernel/linux/files/`.

### AI attribution in patch headers

Same trailer as commits (`AGENTS.md` §"Commit style → AI attribution"):
`Assisted-by: <tool>:<model-id>`, one line per model that touched the
patch, immediately **above** the `Signed-off-by:` line. Never copy a
model id out of a doc or an existing patch — state the model actually
running. Policy applies to patches written or modified from 2026-08-02
onward; existing patches are not retrofitted, because reconstructing
which model wrote them from memory would fabricate the audit trail the
trailer exists to provide.

Which patches it applies to depends on `Upstream-Status`:

| Status | AI trailer |
|---|---|
| `Inappropriate [...]`, `Denied [...]` | Yes. Never leaves the repo; our rules are the only rules. |
| `Pending`, `Submitted [...]` | Yes here — but the receiving project's trailer rules win at submission time. `Assisted-by:` is not part of the kernel/U-Boot canonical trailer set; check that project's current contribution docs before sending, and be ready to drop it. |
| `Backport [...]`, `Accepted [...]` | **No — do not touch the header.** The commit message and its `Signed-off-by:` chain belong to the original author. Only the `Upstream-Status:` line is ours to add. Adding our trailers misattributes their work and destroys the verbatim-cherry-pick property. |

`Signed-off-by:` stays last and stays a **human**. Attribution records
who helped write the patch; the DCO sign-off certifies who takes
responsibility for it. An `Assisted-by:` line never substitutes for a
sign-off, and an agent never adds a sign-off on the operator's behalf.

## Patch + sstate cascade

Editing a `file://...` patch's HEADER (Upstream-Status, From, Signed-off-by)
invalidates the patch file's content hash and triggers a rebuild of
`do_patch -> do_compile -> do_install -> do_deploy` for that recipe,
even though `patch -p1` would ignore the header text. Batch header
edits before kicking off a build.

## Patch iteration — when to reach for devtool

For known-good patches harvested from another tree (proven to apply
against our target kernel), straight `cp` into the recipe's `files/`
dir + a SRC_URI wire is fine. Confirm portability by checking the
source project's `build/tmp/work/<recipe>/<version>/` already contains
the patches applied against a matching version line.

Reach for the `devtool-workflow` skill (listed in `CLAUDE.md`) when:

- **A harvested patch rejects at `do_patch`** — offset shifts or
  context changes. Don't hand-edit hunks. `devtool modify <recipe>`
  extracts source into a workspace tree, applies what it can, leaves
  rejects; resolve in the workspace tree with git/quilt, then
  `devtool finish <recipe> <layer>` regenerates patches with correct
  context.
- **Authoring a NEW patch** (kernel hack, U-Boot board fix, recipe
  source tweak). The workspace tree is a real git repo; commit per
  logical change, finish emits one patch per commit with consistent
  metadata.
- **A `.cfg` fragment names a `CONFIG_*` symbol that doesn't exist** —
  gone or renamed in the target kernel version. Use `devtool modify`
  + `make menuconfig` to find the new symbol, then regenerate the
  fragment.

End-to-end sequence: `modify → (edit in workspace) → build → commit
→ finish → verify`. See the `devtool-workflow` skill for the full
command-by-command flow.

## meta-arm BBCLASSEXTEND trap on U-Boot

`meta-arm/recipes-bsp/u-boot/u-boot_%.bbappend` sets
`BBCLASSEXTEND = "devupstream:target"` on **every** u-boot recipe in the
build, and overrides `SRC_URI:class-devupstream` to point at denx
mainline master HEAD. That creates a sibling recipe
`virtual:devupstream:target:u-boot_<ver>.bb` pinned to mainline HEAD,
which inherits the BASE recipe's `SRC_URI:append` patch list — so any
board-specific patches in our bbappend get applied against a totally
different upstream than the .bb selects, and almost always fail.

If our recipe is not interested in tracking mainline HEAD (which is
true here — we deliberately use the Renesas CIP fork because mainline
doesn't carry `smarc-rzv2l_defconfig`), drop the variant in **our
bbappend**, not the .bb:

```bitbake
# In meta-edge-bsp/recipes-bsp/u-boot/u-boot_<ver>.bbappend:
BBCLASSEXTEND:remove = "devupstream:target"
```

Why bbappend, not .bb: meta-arm's bbappend is processed alongside ours,
and the last `BBCLASSEXTEND = "..."` assignment wins. The `:remove`
operator is applied during variable expansion regardless of source
order, so it's robust against bbappend ordering between layers.

Symptom you'll see if you forget this: failed task labelled
`virtual:devupstream:target:.../u-boot_<ver>.bb:do_patch` with quilt
complaining `can't find file to patch` or `Hunk #N FAILED`.

## Source layout (`S`, `UNPACKDIR`, `destsuffix`)

- **`S` is auto-derived for a single git `SRC_URI`.** `BB_GIT_DEFAULT_DESTSUFFIX`
  unpacks git to `${UNPACKDIR}/${BP}`, which is also the default `S`. Never set
  `S = "${WORKDIR}/git"` — that path is gone; the recipe breaks at unpack.
- **`file://` sources land in `${UNPACKDIR}`** (= `${WORKDIR}/sources`), not
  `${WORKDIR}`. Reference templates/configs/patches as `${UNPACKDIR}/foo.conf`.
- **Multiple git sources: `destsuffix` is `UNPACKDIR`-relative.** Name each
  (`;name=` + `SRCREV_<name>` + `SRCREV_FORMAT`), give each a `destsuffix=`, and
  set `S` explicitly to the primary — e.g. `destsuffix=tvmrt` →
  `S = "${UNPACKDIR}/tvmrt"`, nested at `destsuffix=tvmrt/sub`. Confirm with
  `bitbake -c unpack <recipe>` before trusting the layout.

## Image-recipe gotchas

- **`debug-tweaks` is gone as an `IMAGE_FEATURES` value** (parse-time error). Use
  the split features explicitly: `empty-root-password`, `allow-empty-password`,
  `allow-root-login`, `serial-autologin-root`.
- **`IMAGE_FSTYPES` needs hard `=`, not `?=`.** oe-core ships
  `IMAGE_FSTYPES ?= "tar.zst"`; a second weak default loses to it and filesystems
  silently fail to build. Use `=` or `:append`.
- **Custom vars in a `.wks` must be added to `WICVARS`** or wic passes them
  through literally — a `${EDGE_FIP_OFFSET}` in a `--source rawcopy` line silently
  lands at the wrong address with no warning.
- **FIT images use `kernel-fit-image.bbclass`**, not a hand-written `.its`. The
  legacy `kernel-fitimage.bbclass` is removed; customize via the declarative
  `oe.fitimage` inputs (`FIT_*`, `KERNEL_DEVICETREE`, signing keys).

