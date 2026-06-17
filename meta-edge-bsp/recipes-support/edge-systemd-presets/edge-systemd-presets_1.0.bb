SUMMARY = "edge-ai-yocto systemd preset overrides"
DESCRIPTION = "Centralizes which systemd units the edge-ai distro wants \
enabled or masked at first boot. Vendor-layer units (v4l2-init, audio-init) \
from meta-rz-distro are suppressed at parse time via BBMASK in kas/base.yml; \
this preset is intentionally near-empty in v0. Add lines here for first-boot \
preset control as needed."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-edge.preset"

inherit allarch systemd

FILES:${PN} = "${systemd_unitdir}/system-preset/90-edge.preset"

do_install() {
    install -d ${D}${systemd_unitdir}/system-preset
    install -m 0644 ${UNPACKDIR}/90-edge.preset ${D}${systemd_unitdir}/system-preset/
}
