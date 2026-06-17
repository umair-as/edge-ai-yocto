SUMMARY     = "Hardware probe: mmc, i2c, usb, pci, can, evdev, devmem"
DESCRIPTION = "Direct hardware-poke userspace for bring-up: i2c-tools, \
mmc-utils, devmem2, usbutils, pciutils, can-utils, evtest, plus kernel-modules \
so newly-enabled drivers are runtime-available without rebuilding the image."
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
    kernel-modules \
"
