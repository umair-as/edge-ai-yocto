SUMMARY     = "Media userspace: V4L2 (camera) + ALSA (audio) slices"
DESCRIPTION = "Two slices: ${PN}-camera (v4l-utils — v4l2-ctl, media-ctl) and \
${PN}-audio (alsa-utils — aplay, amixer, speaker-test). ${PN} pulls both. \
Board-agnostic; harmless on boards without the relevant MACHINE_FEATURES."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "multimedia"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
PACKAGES = " \
    ${PN} \
    ${PN}-camera \
    ${PN}-audio \
"

RDEPENDS:${PN} = " \
    ${PN}-camera \
    ${PN}-audio \
"

RDEPENDS:${PN}-camera = "v4l-utils"
RDEPENDS:${PN}-audio  = "alsa-utils"
