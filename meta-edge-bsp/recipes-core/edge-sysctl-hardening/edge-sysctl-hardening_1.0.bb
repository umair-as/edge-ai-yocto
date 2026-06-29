SUMMARY     = "sysctl hardening drop-in (CIS Level-1 aligned)"
DESCRIPTION = "Ships /etc/sysctl.d/70-edge-hardening.conf with a baseline \
policy across kernel (dmesg/kptr/BPF/userns/ptrace/kexec/perf), filesystem \
protections, and conservative network defaults. Applied by systemd-sysctl."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = "file://70-edge-hardening.conf"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/70-edge-hardening.conf \
        ${D}${sysconfdir}/sysctl.d/70-edge-hardening.conf
}

FILES:${PN} = "${sysconfdir}/sysctl.d/70-edge-hardening.conf"

# Applied by systemd-sysctl, which is part of systemd. No explicit
# RDEPENDS — systemd is unconditional in this distro (DISTRO_FEATURES).
