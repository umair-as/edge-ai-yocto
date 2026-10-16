SUMMARY     = "Hardware probe: mmc, i2c, usb, pci, can, evdev, devmem, dt, fs"
DESCRIPTION = "Bring-up userspace for direct hardware access: i2c, mmc, devmem, usb, pci, \
CAN, evdev, device-tree and ext4 metadata tools, plus kernel-modules so newly \
enabled drivers load without an image rebuild."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
RDEPENDS:${PN} = " \
    mmc-utils \
    i2c-tools \
    devmem2 \
    usbutils \
    pciutils \
    can-utils \
    evtest \
    dtc \
    e2fsprogs-tune2fs \
    kernel-modules \
"
