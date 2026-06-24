SUMMARY     = "udev rules: render-group access to DRP-AI device nodes"
DESCRIPTION = "Sets group 'render' and mode 0660 on /dev/drpai0 and /dev/udmabuf0 \
so rootless containers (run with --group-add keep-groups) can open the DRP-AI \
accelerator and its zero-copy dma-buf. The nodes are otherwise 0600 root."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://71-edge-drpai.rules"

inherit allarch

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/71-edge-drpai.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/71-edge-drpai.rules"

RDEPENDS:${PN} = "udev"
