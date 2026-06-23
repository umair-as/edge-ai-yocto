SUMMARY = "Stable RAUC slot udev symlinks for the edge-ai distro"
DESCRIPTION = "Provides /dev/disk/by-rauc-slot/{boot,rootfsA,rootfsB,data} \
symlinks based on partition identity (mmcblk0pN on MBR, GPT PARTLABEL on the \
emmc target). This avoids slot lookup failures if ext4 labels change during OTA writes."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "base"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://99-edge-rauc-slots.rules \
    file://99-edge-rauc-slots-gpt.rules \
"

S = "${UNPACKDIR}"

# Boot target picks the rule keying: esd/MBR has no PARTLABEL so it keys on
# mmcblk0pN; emmc/GPT keys on ID_PART_ENTRY_NAME. Both install to the same
# filename so FILES and the RAUC by-rauc-slot devices are identical.
do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    if [ "${EDGE_BOOT_TARGET}" = "emmc" ]; then
        install -m 0644 ${UNPACKDIR}/99-edge-rauc-slots-gpt.rules \
            ${D}${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules
    else
        install -m 0644 ${UNPACKDIR}/99-edge-rauc-slots.rules \
            ${D}${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules
    fi
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules"

RDEPENDS:${PN} = "udev"
