SUMMARY     = "Media userspace: V4L2 (camera) + ALSA (audio) slices"
DESCRIPTION = "Two slices: ${PN}-camera (v4l-utils plus the RZ/V2L OV5645 \
pipeline-init helper, Renesas-patched gstreamer with vspmfilter, and the \
VSPM/mmngr/mmngrbuf userspace modules) and ${PN}-audio (alsa-utils — \
aplay, amixer, speaker-test). ${PN} pulls both."
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

# RZ/V2L camera + display stack. Curated rather than pulling
# meta-renesas's packagegroup-gstreamer1.0-plugins umbrella: that
# scarthgap-era group RDEPENDS on AAC (-bad-faac/-faad), ASF
# (-ugly-asf), and an RTSP server we don't ship, and assumes meta-
# multimedia is in the layer set for faac/faad2. The list below covers
# the v4l2src → vspmfilter → waylandsink camera-preview pipeline
# (the OV5645 → CRU → HDMI demo path) and nothing else.
# multimedia-libs stays from meta-renesas — it's just the VSPM/mmngr/
# mmngrbuf userspace that vspmfilter needs at runtime.
RDEPENDS:${PN}-camera:append:smarc-rzv2l = " \
    edge-ov5645-init \
    gstreamer1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad-waylandsink \
    gstreamer1.0-plugin-vspmfilter \
    packagegroup-multimedia-libs \
"

RDEPENDS:${PN}-audio  = "alsa-utils"
