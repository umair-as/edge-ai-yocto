SUMMARY     = "DX-M1 runtime integration: dxrt service account, device policy, dxrtd unit"
DESCRIPTION = "Project-owned glue for the DEEPX DX-M1 accelerator: the dxrt \
system account and group, udev ownership of /dev/dxrt* (root:dxrt 0660, \
replacing the vendor's 0666), a confined systemd unit for the DXRT daemon, \
and the host-side wiring (profile.d + sudoers) for its fixed IPC endpoint."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://dxrtd.service \
    file://71-edge-dxm1.rules \
    file://edge-dxrt-env.sh \
    file://20-edge-dxrt-env \
"

inherit systemd useradd

S = "${UNPACKDIR}"

# uid/gid 609 from files/{passwd,group} via useradd-staticids. The group is
# what carries device access: /dev/dxrt* is root:dxrt 0660 and the daemon is
# in dxrt. edge-ctr's membership is added at image assembly through
# EDGE_ACCEL_SUPPLEMENTARY_GROUPS (kas/accel/dxm1.yml), not here: a
# recipe-level --groups races the other recipe's groupadd.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system dxrt"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /var/lib/dxrt \
                       --shell /sbin/nologin --gid dxrt dxrt"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "dxrtd.service"
SYSTEMD_AUTO_ENABLE = "enable"

# dx-rt, not dx-rt-cli: upstream appends -cli/-examples to PACKAGES after
# ${PN}, whose default FILES already claims ${bindir}, so those two come out
# empty and are never produced. dxrtd ships in dx-rt.
RDEPENDS:${PN} = "dx-rt"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dxrtd.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/71-edge-dxm1.rules ${D}${sysconfdir}/udev/rules.d/

    install -d ${D}${localstatedir}/lib/dxrt

    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${UNPACKDIR}/edge-dxrt-env.sh ${D}${sysconfdir}/profile.d/

    install -d -m 0750 -o root -g root ${D}${sysconfdir}/sudoers.d
    install -m 0440 -o root -g root ${UNPACKDIR}/20-edge-dxrt-env \
        ${D}${sysconfdir}/sudoers.d/20-edge-dxrt-env
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/dxrtd.service \
    ${sysconfdir}/udev/rules.d/71-edge-dxm1.rules \
    ${localstatedir}/lib/dxrt \
    ${sysconfdir}/profile.d/edge-dxrt-env.sh \
    ${sysconfdir}/sudoers.d/20-edge-dxrt-env \
"

# Matches edge-sudoers' 10-edge-wheel: the 0440 sudoers.d drop-in trips
# do_package's rdepends QA check without this.
INSANE_SKIP:${PN} = "rdepends"

# StateDirectory=dxrt in the unit owns the directory at runtime; the
# image-time chown covers the read-only root, where systemd cannot fix it up.
pkg_postinst:${PN}() {
    chown dxrt:dxrt $D${localstatedir}/lib/dxrt || true
}
