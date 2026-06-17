SUMMARY     = "journald hardening drop-in + persistent journal directory"
DESCRIPTION = "Drops a journald.conf.d hardening drop-in (bounded disk, rate \
limit, no syslog/kmsg forward, Storage=persistent) and a tmpfiles entry that \
creates /var/log/journal. /var/log is bind-mounted from /data by edge-persistence \
so journals survive RAUC slot swaps."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = " \
    file://10-edge-hardening.conf \
    file://edge-journald.conf \
"

S = "${UNPACKDIR}"

RDEPENDS:${PN} = "edge-persistence"

do_install() {
    install -d ${D}${sysconfdir}/systemd/journald.conf.d
    install -m 0644 ${UNPACKDIR}/10-edge-hardening.conf \
        ${D}${sysconfdir}/systemd/journald.conf.d/10-edge-hardening.conf

    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/edge-journald.conf \
        ${D}${libdir}/tmpfiles.d/edge-journald.conf
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/journald.conf.d/10-edge-hardening.conf \
    ${libdir}/tmpfiles.d/edge-journald.conf \
"
