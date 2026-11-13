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

require edge-bundle-${EDGE_BOOT_CHAIN}.inc

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"
