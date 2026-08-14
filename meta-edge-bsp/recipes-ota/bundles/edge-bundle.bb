SUMMARY = "RAUC rootfs and signed slot-FIT bundle for the edge-ai distro"
DESCRIPTION = "Produces a coordinated dm-verity rootfs and signed boot-policy update."

require edge-bundle-common.inc

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"
