SUMMARY     = "Login motd dynamic appendix + sshd banner drop-in"
DESCRIPTION = "Ships /etc/profile.d/edge-motd-dynamic.sh — a POSIX-sh appendix \
sourced by interactive shells that prints live system state (hostname, DT \
model, kernel, IP, uptime, RAUC slot). Also ships the sshd Banner drop-in."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://edge-motd-dynamic.sh \
    file://sshd_banner.conf \
"

inherit allarch

S = "${UNPACKDIR}"

# iproute2 for `ip` in the dynamic appendix. No rauc/busctl runtime
# dependency — RAUC slot is parsed from /proc/cmdline.
RDEPENDS:${PN} = "iproute2"

do_install() {
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${UNPACKDIR}/edge-motd-dynamic.sh \
        ${D}${sysconfdir}/profile.d/edge-motd-dynamic.sh

    # sshd Banner drop-in. Path comes from openssh's default sshd_config:
    # `Include /etc/ssh/sshd_config.d/*.conf`.
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${UNPACKDIR}/sshd_banner.conf \
        ${D}${sysconfdir}/ssh/sshd_config.d/10-edge-banner.conf
}

FILES:${PN} = " \
    ${sysconfdir}/profile.d/edge-motd-dynamic.sh \
    ${sysconfdir}/ssh/sshd_config.d/10-edge-banner.conf \
"
