SUMMARY     = "systemd runtime + reboot hardware-watchdog policy"
DESCRIPTION = "Ships /etc/systemd/system.conf.d/10-edge-watchdog.conf so PID 1 \
arms and pings /dev/watchdog0 (RZ/G2L WDT). Reboots the board on a hard hang \
that panic_on_oops cannot catch, feeding the RAUC recovery-slot path."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = "file://10-edge-watchdog.conf"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${UNPACKDIR}/10-edge-watchdog.conf \
        ${D}${sysconfdir}/systemd/system.conf.d/10-edge-watchdog.conf
}

FILES:${PN} = "${sysconfdir}/systemd/system.conf.d/10-edge-watchdog.conf"

# Read by systemd-PID1 manager config. No explicit RDEPENDS — systemd is
# unconditional in this distro (DISTRO_FEATURES).
