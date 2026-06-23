SUMMARY = "First-boot /data growth for both eSD/MBR and eMMC/GPT layouts"
DESCRIPTION = "Grows /data to fill the storage device on first boot via a single \
oneshot that dispatches on the partition table: systemd-repart for GPT (eMMC), \
parted for MBR (eSD), with a shared resize2fs + tune2fs filesystem tail."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "base"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://edge-grow-data.sh \
    file://edge-grow-data.service \
    file://50-data.conf \
"

S = "${UNPACKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "edge-grow-data.service"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/edge-grow-data.sh ${D}${sbindir}/edge-grow-data.sh

    install -d ${D}${sysconfdir}/repart.d
    install -m 0644 ${UNPACKDIR}/50-data.conf ${D}${sysconfdir}/repart.d/50-data.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/edge-grow-data.service \
        ${D}${systemd_system_unitdir}/edge-grow-data.service
}

FILES:${PN} = " \
    ${sbindir}/edge-grow-data.sh \
    ${sysconfdir}/repart.d/50-data.conf \
    ${systemd_system_unitdir}/edge-grow-data.service \
"

# parted+partprobe (MBR), systemd-repart+udevadm (GPT), e2fsprogs (e2fsck,
# resize2fs, tune2fs, mkfs.ext4), util-linux (lsblk, blkid).
RDEPENDS:${PN} = "bash parted e2fsprogs e2fsprogs-resize2fs e2fsprogs-tune2fs util-linux udev systemd"
