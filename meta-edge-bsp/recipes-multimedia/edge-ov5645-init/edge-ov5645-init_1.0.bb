SUMMARY     = "Pipeline-format setup helper for the OV5645 CSI camera"
DESCRIPTION = "Installs /usr/libexec/edge-ov5645-init.sh which configures the \
rzg2l-cru media-controller pipeline (sensor → CSI-2 → CRU IP → /dev/video0) \
to a matching format/resolution. Without this, VIDIOC_STREAMON returns -1 \
(Broken pipe). On-demand, not a boot-time service."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "multimedia"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = "file://edge-ov5645-init.sh"

S = "${UNPACKDIR}"

RDEPENDS:${PN} = "v4l-utils"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/edge-ov5645-init.sh \
        ${D}${libexecdir}/edge-ov5645-init.sh
}

FILES:${PN} = "${libexecdir}/edge-ov5645-init.sh"

# OV5645 wiring is RZ/V2L-specific.
COMPATIBLE_MACHINE = "smarc-rzv2l"
