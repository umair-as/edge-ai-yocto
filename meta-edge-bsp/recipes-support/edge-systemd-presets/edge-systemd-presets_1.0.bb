SUMMARY = "edge-ai-yocto systemd preset overrides"
DESCRIPTION = "systemd preset (90-edge.preset) for the units the edge-ai distro enables at \
first boot. Renesas vendor units are masked at parse time by BBMASK in \
kas/bsp/renesas-rz.yml."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "base"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-edge.preset"

inherit allarch systemd

FILES:${PN} = "${systemd_unitdir}/system-preset/90-edge.preset"

do_install() {
    install -d ${D}${systemd_unitdir}/system-preset
    install -m 0644 ${UNPACKDIR}/90-edge.preset ${D}${systemd_unitdir}/system-preset/
}
