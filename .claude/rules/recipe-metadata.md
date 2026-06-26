# Recipe metadata — canonical header layout

Distilled from `openembedded-core/meta/conf/documentation.conf`,
the bitbake user manual
(`bitbake/doc/bitbake-user-manual/bitbake-user-manual-metadata.rst`,
`...-ref-variables.rst`), and the OE-Core recipe corpus
(`meta/recipes-*/`). The pinned authoritative source lives in-tree at
the kas-cloned `openembedded-core/` and `bitbake/` checkouts — open
those when this rule is ambiguous.

These rules apply to every `.bb` we author in `meta-edge-bsp` and
`meta-edge-distro`.

## Canonical header order

OE-Core's settled convention (cross-checked against `busybox.inc`,
`tar_*.bb`, `curl_*.bb`, `wget_*.bb` in wrynose) is:

```bitbake
SUMMARY     = "Short one-liner, ≤80 chars, no trailing period"
DESCRIPTION = "Longer paragraph. Wrap lines with backslash-continuation. \
Multiple sentences are fine — DESCRIPTION is what end users see in \
package managers (rpm -qi, apt show)."
HOMEPAGE    = "https://upstream.project.tld/"
SECTION     = "base"             # see SECTION categories below
LICENSE     = "MIT"              # SPDX identifier (or expression with & / |)
LIC_FILES_CHKSUM = "file://COPYING;md5=..."

# Source
SRC_URI = " \
    https://upstream/.../${BP}.tar.xz \
    file://0001-local-patch.patch \
"
SRC_URI[sha256sum] = "..."        # for http(s) tarballs
SRCREV = "..."                    # for git fetches; pin to a commit, no AUTOREV
                                  # except for AUTOREV-by-design (CVE-DB recipes)

# Recipe-system metadata (only when relevant)
CVE_PRODUCT          = "vendor:product"
UPSTREAM_CHECK_URI   = "https://.../releases"
UPSTREAM_CHECK_REGEX = "..."

# Dependencies
DEPENDS  = "..."
RDEPENDS:${PN} = "..."

# Behavior
inherit ...
S = "${UNPACKDIR}"               # wrynose default; never ${WORKDIR}

# Tasks
do_configure() { ... }
do_compile() { ... }
do_install() { ... }

# Packaging
FILES:${PN} = "..."
```

Every field above is a deliberate signal to a downstream consumer
(package manager, SBOM, CVE checker, devtool, AUH). Set them
accurately, but keep them terse — a verbose `DESCRIPTION` or a
marketing-flavoured `SUMMARY` is worse than a missing one. The
required list below is short on purpose.

## Required (no exceptions) for every `.bb` we write

| Field              | Why                                                                |
|--------------------|--------------------------------------------------------------------|
| `SUMMARY`          | rpm/dpkg `Summary:`; first thing a human sees. **Hard cap ≤80 chars.** |
| `DESCRIPTION`      | rpm/dpkg `Description:`. Defaults to SUMMARY if unset, but be explicit. **Hard cap ≤3 wrapped lines.** |
| `LICENSE`          | License-manifest, SPDX SBOM, `INCOMPATIBLE_LICENSE` filtering.    |
| `LIC_FILES_CHKSUM` | Detects upstream license change → fail build. Required by `license.bbclass`. |
| `HOMEPAGE`         | SPDX `PackageHomePage`. Reviewer's first click during audit.       |
| `SECTION`          | Package-tool categorization. Use the list below — don't invent.   |

## `BUGTRACKER` — when to set it, when to omit it

- **Internal recipes** (anything we author in `meta-edge-bsp` /
  `meta-edge-distro` that ships our own artifacts): **omit `BUGTRACKER`.**
  This is a personal project; it does not accept external bug reports
  and pointing at a public issue tracker implies a support contract we
  do not offer.
- **Upstream-tracking recipes** (bbappend or `.bb` that pulls source
  from TF-A, U-Boot, linux-cip, OP-TEE, etc.): set `BUGTRACKER` to the
  *upstream* project's tracker, not ours. This is what the field is for
  — pointing CVE workflow and a reviewer at where to file the real bug.

## Recommended for upstream-tracking recipes

When a recipe pulls source from an external project (TF-A, U-Boot,
OP-TEE, linux-cip), add the recipe-system metadata that lets the
ecosystem tools work:

- `CVE_PRODUCT = "vendor:product"` — without this, `cve-check` (now
  `sbom-cve-check` in wrynose) can't map the recipe to NVD entries.
  Names from the NVD CPE dictionary. Multiple aliases are space-separated
  (see `curl_*.bb:26` for the canonical many-name example).
- `UPSTREAM_CHECK_URI` + `UPSTREAM_CHECK_REGEX` — drives AUH
  (auto-upgrade-helper) and `devtool latest-version`. The regex captures
  the version into named group `pver`. See
  `meta/recipes-extended/lsb/lsb-release_1.4.bb` and `pigz_2.8.bb` for
  patterns.
- `RECIPE_NO_UPDATE_REASON` — set this on a recipe deliberately pinned
  off-latest. Tells AUH not to file noise about it.

## SECTION categories

OE-Core uses a small fixed vocabulary. Pick the closest match — don't
invent new ones (they fragment the package-manager UI).

| SECTION              | When                                                      |
|----------------------|-----------------------------------------------------------|
| `base`               | Core system (init, libc-adjacent, busybox-tier)           |
| `bootloaders`        | U-Boot, TF-A, OP-TEE, FIT image plumbing                  |
| `kernel`             | Linux kernel and kernel modules                           |
| `console/network`    | CLI network tools (curl, wget, ssh client)                |
| `console/utils`      | CLI userland (coreutils-adjacent)                         |
| `libs`               | Shared libraries                                          |
| `devel`              | Headers, dev tooling, SDK pieces                          |
| `graphics`           | X / Wayland / Mesa / DRM / weston                         |
| `multimedia`         | gstreamer, ffmpeg, audio                                  |
| `firmware`           | Binary firmware blobs                                     |
| `recipes-bsp`        | (filesystem layout convention, not a SECTION value)       |

For our own recipes:
- `edge-splash-assets`            → `bootloaders` (U-Boot consumes it)
- `u-boot-env-config`             → `bootloaders`
- `edge-slot-udev`                → `base`
- `edge-systemd-presets`          → `base`
- `rauc-conf-edge`, `edge-bundle` → `console/utils` (RAUC is in `console/utils` upstream)

## SUMMARY + DESCRIPTION — keep them terse

`SUMMARY` and `DESCRIPTION` are package-manager fields, not a place
to relitigate a design decision. Detailed rationale goes in
`docs/adr/`; package-list inventories are derivable from `RDEPENDS`
and don't belong in `DESCRIPTION`.

**SUMMARY rules**:
- ≤80 chars. Hard cap; no exceptions.
- No trailing period.
- No distro-name prefix ("EDGE AI OS", "edge-ai-yocto") — the recipe
  already lives in the edge layer; the prefix is filler.
- Lead with the artifact or function, not the marketing framing.

**DESCRIPTION rules**:
- ≤3 wrapped lines. One paragraph, joined with `\` continuation.
- State what the recipe deposits on disk and the slot it fills.
- No bulleted package inventories — that's what `RDEPENDS` is for.
- No multi-paragraph essays, no "Contents:" tables, no "Why we
  chose X over Y" narratives. Put that in `docs/adr/` and reference
  the ADR by number in a one-line comment if needed.
- Don't restate the recipe name. "edge-splash-assets is a recipe that
  provides edge splash assets" is filler.
- Don't reference internal task IDs or PR numbers — those rot.

Smell test: if `DESCRIPTION` reads like a README, it's too long.
A reader should be able to absorb it in one glance.

## LIC_FILES_CHKSUM

Three valid sources for the checksum target:

1. **A file inside the source tree**:
   `LIC_FILES_CHKSUM = "file://COPYING;md5=..."`
   Use when upstream ships a license file.

2. **The common license dir** (for permissive licenses on internal
   recipes that don't have their own COPYING):
   `LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"`
   This is what all our internal-only recipes use today.

3. **A range within a source file** (when the license is embedded in a
   header):
   `LIC_FILES_CHKSUM = "file://main.c;beginline=1;endline=20;md5=..."`

The MD5 is the on-disk file hash. Editing the license file → editing
the checksum. If you don't update both, the build fails — which is the
intended behavior.

## SRC_URI hashes

Required for any non-SCM fetcher (https, http, ftp, file from a
remote). Format: `SRC_URI[sha256sum] = "..."`. Add it on a new line
after the `SRC_URI` block, not as a URL parameter.

For git fetches use `SRCREV` (full 40-char SHA, no `AUTOREV` except
the CVE-DB recipes that are AUTOREV by design — see
`yocto-patterns.md`).

For local `file://` URIs inside `SRC_URI`, no hash is needed — the
file lives in the layer and is content-hashed implicitly.

## inherit ordering

Convention from OE-Core: group `inherit` lines together, after the
metadata block and before tasks. Multiple inherits on one line are
preferred over multiple `inherit` lines when they're related:

```bitbake
inherit autotools gettext pkgconfig             # one logical group
inherit update-rc.d systemd                     # service-management group
```

Common inherits we use:

- `allarch` — recipe produces architecture-independent output (configs,
  scripts, assets). Cuts build matrix.
- `systemd` — exposes `SYSTEMD_SERVICE:${PN}` and friends; pairs with
  `SYSTEMD_AUTO_ENABLE:${PN} = "enable"|"disable"`.
- `deploy` — adds `do_deploy` task; lets a recipe place artifacts in
  `${DEPLOYDIR}` for WIC / wic-image-* to pick up.
- `useradd` — when the package needs a system user.

## `:append` vs `+=` vs `=` for SRC_URI

- `=` — replaces. Use in a `.bb` for the canonical list.
- `:append` — adds with one leading space, late binding. Use in a
  `.bbappend` to add patches/files without disturbing the base recipe.
- `+=` — adds with one space, early binding. Mostly avoid in .bbappend;
  it interacts confusingly with overrides.

Pattern in our `.bbappend`s:

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " \
    file://0001-board-fix.patch \
    file://board.cfg \
"
```

Note the leading space inside the quotes — required, easy to forget.

## Override syntax reminder

Wrynose uses `:` (see `yocto-patterns.md`). For metadata variables:

```bitbake
SUMMARY:smarc-rzv2l = "...board-specific summary..."   # rare; usually no
RDEPENDS:${PN}      = "foo bar"
SRC_URI:append:smarc-rzv2l = " file://board-patch.patch"
```

Don't write `RDEPENDS_${PN}` — parser rejects it on wrynose.

## What our internal recipes look like, fully populated

Example: `edge-slot-udev_1.0.bb` with canonical metadata. Adapt this
template for any new internal recipe.

```bitbake
SUMMARY     = "Stable RAUC slot udev symlinks for the edge distro"
DESCRIPTION = "Provides /dev/disk/by-rauc-slot/{boot,rootfsA,rootfsB,data} \
symlinks based on partition identity (mmcblk0pN). This avoids slot lookup \
failures if ext4 labels change during OTA writes."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-edge-rauc-slots.rules"

inherit allarch

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${nonarch_base_libdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-edge-rauc-slots.rules \
        ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/99-edge-rauc-slots.rules"
```

## Audit (state at the time this rule was written)

Run from repo root to recheck:

```bash
for f in $(find meta-edge-bsp meta-edge-distro -name "*.bb"); do
  miss=""
  grep -q "^SUMMARY"     "$f" || miss="$miss SUMMARY"
  grep -q "^DESCRIPTION" "$f" || miss="$miss DESCRIPTION"
  grep -q "^HOMEPAGE"    "$f" || miss="$miss HOMEPAGE"
  grep -q "^SECTION"     "$f" || miss="$miss SECTION"
  grep -q "^LICENSE"     "$f" || miss="$miss LICENSE"
  [ -n "$miss" ] && echo "$f  missing:$miss"
done

# Length check: flag overlong SUMMARY (>80) and bloated DESCRIPTION
# (>3 logical lines). Internal recipes that fail this are bugs.
for f in $(find meta-edge-bsp meta-edge-distro -name "*.bb"); do
  awk '/^SUMMARY[ \t]*=/ { gsub(/^[^"]*"|"[^"]*$/, ""); if (length > 80)
        print FILENAME ": SUMMARY " length " chars"; exit }' "$f"
done

# BUGTRACKER on an internal recipe is also a bug — should only appear
# on upstream-tracking recipes pointing at the *upstream* tracker.
grep -lR "^BUGTRACKER.*umair-as/edge-ai-yocto" meta-edge-bsp meta-edge-distro \
  | sed 's/^/internal-bugtracker: /'
```


Image recipes (`edge-image-base.bb`) and bundle recipes
(`edge-bundle.bb`) inherit their metadata from `image.bbclass` /
`bundle.bbclass`. Still — set `SUMMARY` and `DESCRIPTION` directly on
the recipe so `bitbake-layers show-recipes` is informative.

## Where the upstream rules live (read these when in doubt)

- `bitbake/doc/bitbake-user-manual/bitbake-user-manual-ref-variables.rst`
  — every variable, with a sentence each. Long; ctrl-F it.
- `openembedded-core/meta/conf/documentation.conf` — the `[doc]` flag
  index. One-line definition for every recipe variable. Authoritative.
- `openembedded-core/meta-skeleton/recipes-skeleton/{hello-single,service}/`
  — minimal recipe templates from upstream.
- `openembedded-core/meta/conf/distro/include/maintainers.inc` — the
  `RECIPE_MAINTAINER:pn-foo = "..."` pattern, if we ever maintain one.
- OE-Core recipes themselves: read `busybox.inc`, `tar_*.bb`,
  `curl_*.bb`, `wget_*.bb` for canonical examples of headers,
  packaging, CVE wiring, and upstream-check setup.
