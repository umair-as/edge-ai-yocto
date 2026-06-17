SUMMARY = "RAUC bundle (rootfs-only) for the edge-ai distro"
DESCRIPTION = "Produces a RAUC bundle that updates only the rootfs slot."

require edge-bundle-common.inc

EDGE_RAUC_UPDATE_BOOTFILES = "0"
BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"
