SUMMARY     = "Bind /var/log, /var/lib state, and /home from /data"
DESCRIPTION = "Four .mount units bind /data/{log,containers,systemd,home} \
over the matching paths; two oneshot services capture-or-restore \
/etc/machine-id and the sshd host keys across RAUC slot swaps."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://var-log.mount \
    file://var-lib-containers.mount \
    file://var-lib-systemd.mount \
    file://home.mount \
    file://edge-persistence.tmpfiles \
    file://edge-data-seed.service \
    file://edge-data-seed.sh \
    file://edge-machine-id-persist.service \
    file://edge-machine-id-persist.sh \
    file://edge-ssh-host-keys-persist.service \
    file://edge-ssh-host-keys-persist.sh \
    file://systemd-logind-after-data.conf \
"

S = "${UNPACKDIR}"

inherit systemd

# The .mount units are pulled into local-fs.target via their [Install] sections;
# the oneshot identity-persist services are pulled in by sshd.service /
# systemd-machine-id-commit.service indirectly. SYSTEMD_SERVICE lists them so
# the systemd preset enables/disables them correctly.
SYSTEMD_SERVICE:${PN} = " \
    var-log.mount \
    var-lib-containers.mount \
    var-lib-systemd.mount \
    home.mount \
    edge-data-seed.service \
    edge-machine-id-persist.service \
    edge-ssh-host-keys-persist.service \
"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-log.mount                  ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/var-lib-containers.mount       ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/var-lib-systemd.mount          ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/home.mount                     ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/edge-data-seed.service         ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/edge-machine-id-persist.service    ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/edge-ssh-host-keys-persist.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/edge-data-seed.sh              ${D}${sbindir}/edge-data-seed
    install -m 0755 ${UNPACKDIR}/edge-machine-id-persist.sh     ${D}${sbindir}/edge-machine-id-persist
    install -m 0755 ${UNPACKDIR}/edge-ssh-host-keys-persist.sh  ${D}${sbindir}/edge-ssh-host-keys-persist

    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/edge-persistence.tmpfiles ${D}${libdir}/tmpfiles.d/edge-persistence.conf

    # Order logind after the /var/lib/systemd bind so it sees linger markers.
    install -d ${D}${systemd_system_unitdir}/systemd-logind.service.d
    install -m 0644 ${UNPACKDIR}/systemd-logind-after-data.conf \
        ${D}${systemd_system_unitdir}/systemd-logind.service.d/10-edge-linger-after-data.conf
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/var-log.mount \
    ${systemd_system_unitdir}/var-lib-containers.mount \
    ${systemd_system_unitdir}/var-lib-systemd.mount \
    ${systemd_system_unitdir}/home.mount \
    ${systemd_system_unitdir}/edge-data-seed.service \
    ${systemd_system_unitdir}/edge-machine-id-persist.service \
    ${systemd_system_unitdir}/edge-ssh-host-keys-persist.service \
    ${sbindir}/edge-data-seed \
    ${sbindir}/edge-machine-id-persist \
    ${sbindir}/edge-ssh-host-keys-persist \
    ${libdir}/tmpfiles.d/edge-persistence.conf \
    ${systemd_system_unitdir}/systemd-logind.service.d/10-edge-linger-after-data.conf \
"

# edge-ssh-host-keys-persist generates host keys on first boot.
RDEPENDS:${PN} = "openssh-keygen"
