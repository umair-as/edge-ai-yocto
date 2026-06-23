SUMMARY = "U-Boot env init for RAUC's A/B slot state machine"
DESCRIPTION = "Installs /etc/fw_env.config (locating the env in MMC raw area), \
the RAUC-aware env-init oneshot service, the managed env defaults file, and \
/etc/u-boot-initial-env (libubootenv's defenv fallback — without this file, \
fw_setenv against an uninitialized env area returns -EACCES and the env-init \
script bails on first boot, never writing the FIT-aware bootcmd to MMC)."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "bootloaders"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Runtime virtual provider — packagegroup-edge-base RDEPENDS on the
# virtual, not on this PN directly, so a mender-uboot-env recipe (when
# it ever lands) supplies the same shape via PREFERRED_RPROVIDER in
# edge-ota-mender.inc. See ADR-0005.
RPROVIDES:${PN} = "virtual-ota-uboot-env"

inherit allarch systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://fw_env.config \
    file://rauc-uboot-env.defaults \
    file://rauc-uboot-env-init.service \
    file://rauc-uboot-env-init.sh \
"

# Dev-only netboot fragment, gated by edge.conf's EDGE_DEV_NETBOOT.
# Appended to the deployed defaults at image-build time when "1";
# otherwise no bytes from this file ship in the image at all.
SRC_URI:append = "${@' file://rauc-uboot-env.dev-netboot' if d.getVar('EDGE_DEV_NETBOOT') == '1' else ''}"

S = "${UNPACKDIR}"

RDEPENDS:${PN} = "u-boot-fw-utils bash"

SYSTEMD_SERVICE:${PN} = "rauc-uboot-env-init.service"
SYSTEMD_AUTO_ENABLE   = "enable"

do_install() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/fw_env.config           ${D}${sysconfdir}/fw_env.config
    install -m 0644 ${UNPACKDIR}/rauc-uboot-env.defaults ${D}${sysconfdir}/rauc-uboot-env.defaults

    # libubootenv's fw_setenv looks for /etc/u-boot-initial-env as the
    # default-environment fallback when the on-device MMC env CRC is invalid
    # (first boot after flash). Without this file fw_setenv errors out with
    # -EACCES, even though the device is writable — the tool refuses to
    # construct an env from scratch with no defenv to seed from. Ship the
    # same KEY=VALUE content as rauc-uboot-env.defaults so the seed env and
    # the values our init script writes agree.
    install -m 0644 ${UNPACKDIR}/rauc-uboot-env.defaults ${D}${sysconfdir}/u-boot-initial-env

    # Conditionally append the dev netboot env macro to BOTH the
    # managed defaults (consumed by rauc-uboot-env-init.sh) AND the
    # u-boot-initial-env defenv seed. Both must agree or fw_setenv's
    # first-boot path won't see the macro until env migration runs.
    if [ "${EDGE_DEV_NETBOOT}" = "1" ]; then
        cat ${UNPACKDIR}/rauc-uboot-env.dev-netboot \
            >> ${D}${sysconfdir}/rauc-uboot-env.defaults
        cat ${UNPACKDIR}/rauc-uboot-env.dev-netboot \
            >> ${D}${sysconfdir}/u-boot-initial-env
    fi

    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/rauc-uboot-env-init.sh ${D}${sbindir}/rauc-uboot-env-init.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/rauc-uboot-env-init.service ${D}${systemd_unitdir}/system/rauc-uboot-env-init.service
}

FILES:${PN} = " \
    ${sysconfdir}/fw_env.config \
    ${sysconfdir}/rauc-uboot-env.defaults \
    ${sysconfdir}/u-boot-initial-env \
    ${sbindir}/rauc-uboot-env-init.sh \
    ${systemd_unitdir}/system/rauc-uboot-env-init.service \
"
