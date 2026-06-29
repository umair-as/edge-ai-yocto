SUMMARY     = "Reversible JTAG/kgdb debug-mode toggle for the edge distro"
DESCRIPTION = "Ships edge-debug-mode, which disarms the runtime watchdog, \
relaxes the kptr/perf/dmesg/sysrq clamps, and quiets the lockup detectors so \
a JTAG core halt does not reset or wedge the board. Reverts on demand."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "devel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://edge-debug-mode \
    file://20-edge-debug-watchdog.conf \
    file://99-edge-debug.conf \
"

inherit allarch

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/edge-debug-mode ${D}${sbindir}/edge-debug-mode

    # Drop-in sources the script copies into /etc on `on`.
    install -d ${D}${datadir}/edge-debug-mode
    install -m 0644 ${UNPACKDIR}/20-edge-debug-watchdog.conf \
        ${D}${datadir}/edge-debug-mode/20-edge-debug-watchdog.conf
    install -m 0644 ${UNPACKDIR}/99-edge-debug.conf \
        ${D}${datadir}/edge-debug-mode/99-edge-debug.conf

    # Debug image (EDGE_ENABLE_JTAG_DEBUG=1): pre-place the drop-ins so the
    # image boots debug-safe without running the script. Default builds ship
    # only the inert tool.
    if [ "${EDGE_ENABLE_JTAG_DEBUG}" = "1" ]; then
        install -d ${D}${sysconfdir}/systemd/system.conf.d
        install -m 0644 ${UNPACKDIR}/20-edge-debug-watchdog.conf \
            ${D}${sysconfdir}/systemd/system.conf.d/20-edge-debug-watchdog.conf
        install -d ${D}${sysconfdir}/sysctl.d
        install -m 0644 ${UNPACKDIR}/99-edge-debug.conf \
            ${D}${sysconfdir}/sysctl.d/99-edge-debug.conf
    fi
}

# The :etc paths are present only in a debug-toggled build; listing them
# unconditionally is harmless (absent files are skipped at packaging).
FILES:${PN} = " \
    ${sbindir}/edge-debug-mode \
    ${datadir}/edge-debug-mode \
    ${sysconfdir}/systemd/system.conf.d/20-edge-debug-watchdog.conf \
    ${sysconfdir}/sysctl.d/99-edge-debug.conf \
"

# Reads the EDGE_ENABLE_JTAG_DEBUG toggle: output differs when set, so the
# task signature must track it.
do_install[vardeps] += "EDGE_ENABLE_JTAG_DEBUG"

# fw_setenv (edge-debug-mode --bootargs) comes from u-boot-fw-utils, already
# in packagegroup-edge-base. systemctl/sysctl are part of systemd.
RDEPENDS:${PN} = "systemd"
