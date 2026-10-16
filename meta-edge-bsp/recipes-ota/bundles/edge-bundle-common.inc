LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle

# Single source of truth: must match rauc-conf-edge byte-for-byte.
RAUC_BUNDLE_COMPATIBLE ?= "edge-ai-${MACHINE}"

RAUC_BUNDLE_SLOTS  = "rootfs"
# Default to the dev image. `make bundle IMAGE=prod` sets BUNDLE_IMAGE_NAME
# and EDGE_PROFILE together; a local.conf assignment overrides the make
# value and splits image from tier.
BUNDLE_IMAGE_NAME ?= "edge-image-dev"
BUNDLE_IMAGE       = "${BUNDLE_IMAGE_NAME}"

RAUC_SLOT_rootfs           = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype]   = "ext4.verity"
RAUC_SLOT_rootfs[imagetype] = "raw"
RAUC_SLOT_rootfs[hooks]    = "pre-install;post-install"

# The slot dependency stops at the image's do_image_complete; its SBOM and
# sbom-cve-check report hang off the image's do_build and are otherwise not
# produced for the bundled rootfs. Off for dev iteration, on for prod.
EDGE_BUNDLE_SBOM_CVE ??= "0"
EDGE_BUNDLE_SBOM_CVE:prod = "1"
do_build[depends] += "${@'${BUNDLE_IMAGE}:do_sbom_cve_check' if d.getVar('EDGE_BUNDLE_SBOM_CVE') == '1' else ''}"

# Disable adaptive updates (block-hash-index) by default. Re-enable per-build
# via EDGE_RAUC_ADAPTIVE=1 for smaller bundle transfer at the cost of
# the longer hash-index compute phase.
EDGE_RAUC_ADAPTIVE         ?= "0"
RAUC_SLOT_rootfs[adaptive] = "${@bb.utils.contains('EDGE_RAUC_ADAPTIVE','1','block-hash-index','',d)}"

require edge-bundle-crypt.inc

# Manifest metadata. bundle.bbclass auto-populates these from PV/SUMMARY/DATETIME
# by default; override so the bundle's [update] section reads correctly on the
# device (rauc status, fleet dashboard).
RAUC_BUNDLE_VERSION     = "${DISTRO_VERSION}"
RAUC_BUNDLE_DESCRIPTION = "EDGE AI OS bundle for ${MACHINE} (image: ${BUNDLE_IMAGE})"
RAUC_BUNDLE_BUILD       = "${EDGE_BUILD_ID}"
RAUC_BUNDLE_BUILD[vardepsexclude] = "EDGE_BUILD_ID DATETIME"

EDGE_RAUC_FIT_A = "${BUNDLE_IMAGE}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}.fitImage-A"
EDGE_RAUC_FIT_B = "${BUNDLE_IMAGE}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}.fitImage-B"
EDGE_RAUC_TRACK_DEPLOY_FILES ?= ""

# The root hash and dm table live in the signed slot FIT. A rootfs-only
# bundle would install an unbootable or unauthenticated slot.
RAUC_BUNDLE_EXTRA_FILES += "${EDGE_RAUC_FIT_A} ${EDGE_RAUC_FIT_B}"
RAUC_BUNDLE_HOOKS[file]    = "bundle-hooks.sh"

# Track selected deploy artifacts in the task hash so sstate invalidates
# on content changes.
python __anonymous() {
    deploy_dir = d.getVar("DEPLOY_DIR_IMAGE")
    files = []

    extra = (d.getVar("EDGE_RAUC_TRACK_DEPLOY_FILES") or "").split()
    files.extend(extra)

    files.extend((d.getVar("EDGE_RAUC_FIT_A"), d.getVar("EDGE_RAUC_FIT_B")))

    if not files:
        return

    files = list(dict.fromkeys(files))
    checksums = d.getVarFlag("do_configure", "file-checksums") or ""
    entries = [f"{deploy_dir}/{name}:True" for name in files]
    d.setVarFlag("do_configure", "file-checksums", (checksums + " " + " ".join(entries)).strip())
}

# Pick up bundle-hooks.sh from the sibling rauc/files directory.
FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:${THISDIR}/../../recipes-bsp/u-boot/files:"
SRC_URI:append = " file://bundle-hooks.sh;mode=0755 file://rauc-uboot-env.defaults.in "
RAUC_BUNDLE_EXTRA_FILES += "rauc-uboot-env.defaults"

# Substitute image-specific bundle filenames before bundle.bbclass copies the
# hook. Slot selection remains a runtime RAUC decision.
do_unpack[postfuncs] += "edge_bundle_substitute_fit_names"
edge_bundle_substitute_fit_names() {
    sed -i \
        -e "s|@FIT_IMAGE_A@|${EDGE_RAUC_FIT_A}|g" \
        -e "s|@FIT_IMAGE_B@|${EDGE_RAUC_FIT_B}|g" \
        "${UNPACKDIR}/bundle-hooks.sh"

    # The bundle ships the U-Boot env defaults so the update hook can seed a
    # slot's env. Same template and same board facts as rauc-uboot-env's
    # do_install -- the file is shared through FILESEXTRAPATHS above, so the
    # two expansions cannot drift in content, only in whether they happen.
    [ -n "${EDGE_SLOT_A_DEVICE}" ] || bbfatal "EDGE_SLOT_A_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
    [ -n "${EDGE_SLOT_B_DEVICE}" ] || bbfatal "EDGE_SLOT_B_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
    sed -e "s|@EDGE_SLOT_A_DEVICE@|${EDGE_SLOT_A_DEVICE}|g" \
        -e "s|@EDGE_SLOT_B_DEVICE@|${EDGE_SLOT_B_DEVICE}|g" \
        "${UNPACKDIR}/rauc-uboot-env.defaults.in" \
        > "${UNPACKDIR}/rauc-uboot-env.defaults"
    if grep -q '@[A-Z_]*@' "${UNPACKDIR}/rauc-uboot-env.defaults"; then
        bbfatal "Unexpanded @TOKEN@ left in the bundle's rauc-uboot-env.defaults"
    fi
}
do_unpack[vardeps] += "EDGE_SLOT_A_DEVICE EDGE_SLOT_B_DEVICE"

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"
