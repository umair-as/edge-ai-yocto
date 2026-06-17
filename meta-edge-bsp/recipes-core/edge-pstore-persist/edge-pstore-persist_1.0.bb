SUMMARY     = "Persist systemd-pstore archives on /data across slot switches"
DESCRIPTION = "Bind-mounts /data/crash/pstore over /var/lib/systemd/pstore via \
a systemd .mount unit so kernel pstore records survive reboot and RAUC slot \
switches, plus a oneshot that compresses + prunes stale records on boot."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://var-lib-systemd-pstore.mount \
    file://edge-pstore.tmpfiles.conf \
    file://edge-pstore-prune.sh \
    file://edge-pstore-prune.service \
    file://10-edge-pstore-persist.conf \
"

inherit allarch systemd

S = "${UNPACKDIR}"

# var-lib-systemd-pstore.mount is pulled in on demand by
# systemd-pstore.service via the RequiresMountsFor= drop-in, so it does
# not need [Install] / a preset.
SYSTEMD_SERVICE:${PN} = "edge-pstore-prune.service"
SYSTEMD_AUTO_ENABLE   = "enable"

RDEPENDS:${PN} = "bash util-linux systemd xz"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/edge-pstore-prune.sh ${D}${sbindir}/edge-pstore-prune

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-systemd-pstore.mount \
        ${D}${systemd_system_unitdir}/var-lib-systemd-pstore.mount
    install -m 0644 ${UNPACKDIR}/edge-pstore-prune.service \
        ${D}${systemd_system_unitdir}/edge-pstore-prune.service

    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/edge-pstore.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/edge-pstore.conf

    install -d ${D}${sysconfdir}/systemd/system/systemd-pstore.service.d
    install -m 0644 ${UNPACKDIR}/10-edge-pstore-persist.conf \
        ${D}${sysconfdir}/systemd/system/systemd-pstore.service.d/10-edge-pstore-persist.conf
}

FILES:${PN} = " \
    ${sbindir}/edge-pstore-prune \
    ${systemd_system_unitdir}/var-lib-systemd-pstore.mount \
    ${systemd_system_unitdir}/edge-pstore-prune.service \
    ${sysconfdir}/tmpfiles.d/edge-pstore.conf \
    ${sysconfdir}/systemd/system/systemd-pstore.service.d/10-edge-pstore-persist.conf \
"
