FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# RAUC daemon extension: ship the rauc-grow-data-partition oneshot that
# resizes /data to fill the SD card on first boot.

SRC_URI:append = " \
    file://rauc-grow-data-partition.service \
    file://grow-data-partition.sh \
"

inherit systemd

SYSTEMD_PACKAGES += "${PN}-grow-data-part"
SYSTEMD_SERVICE:${PN}-grow-data-part = "rauc-grow-data-partition.service"

PACKAGES += "rauc-grow-data-part"

RDEPENDS:${PN}-grow-data-part += "bash parted e2fsprogs e2fsprogs-resize2fs util-linux udev"
RDEPENDS:${PN} += "lvm2"

do_install:append() {
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/rauc-grow-data-partition.service \
        ${D}${systemd_unitdir}/system/rauc-grow-data-partition.service

    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/grow-data-partition.sh \
        ${D}${sbindir}/grow-data-partition.sh
}

FILES:rauc-grow-data-part += " \
    ${systemd_unitdir}/system/rauc-grow-data-partition.service \
    ${sbindir}/grow-data-partition.sh \
"
