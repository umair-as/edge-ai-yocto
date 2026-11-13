SUMMARY = "RAUC rootfs bundle with the slot boot payload for the edge-ai distro"
DESCRIPTION = "Produces a coordinated dm-verity rootfs and boot payload update: the signed \
slot FITs on uboot-fit boards, the slot UKIs on uefi-uki boards."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "console/utils"

require edge-bundle-common.inc

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"
