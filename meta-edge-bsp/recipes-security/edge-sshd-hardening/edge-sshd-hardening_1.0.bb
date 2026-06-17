SUMMARY     = "OpenSSH server hardening drop-in for the edge distro"
DESCRIPTION = "Installs /etc/ssh/sshd_config.d/99-edge-hardening.conf with \
auth-method, session, and crypto policy. Loaded last so it overrides any \
earlier drop-in."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://sshd_hardening.conf"

inherit allarch

S = "${UNPACKDIR}"

RDEPENDS:${PN} = "openssh-sshd"

do_install() {
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${UNPACKDIR}/sshd_hardening.conf \
        ${D}${sysconfdir}/ssh/sshd_config.d/99-edge-hardening.conf
}

FILES:${PN} = "${sysconfdir}/ssh/sshd_config.d/99-edge-hardening.conf"
