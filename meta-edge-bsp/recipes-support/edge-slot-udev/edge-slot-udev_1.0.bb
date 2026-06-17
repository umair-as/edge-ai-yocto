SUMMARY = "Stable RAUC slot udev symlinks for the edge-ai distro"
DESCRIPTION = "Provides /dev/disk/by-rauc-slot/{boot,rootfsA,rootfsB,data} \
symlinks based on partition identity (mmcblk0pN). This avoids slot lookup \
failures if ext4 labels change during OTA writes."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-edge-rauc-slots.rules"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-edge-rauc-slots.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules"

RDEPENDS:${PN} = "udev"
