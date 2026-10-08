SUMMARY     = "Operator-driven Raspberry Pi EEPROM bootloader updater"
DESCRIPTION = "Guarded wrapper over rpi-eeprom-update that stages a bootloader \
EEPROM update to the FAT boot partition for the firmware to self-flash on the \
next reboot. status, stage, and cancel are operator-initiated; no service runs."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "bootloaders"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "raspberrypi5"
PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = "file://edge-rpi-eeprom"
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/edge-rpi-eeprom ${D}${sbindir}/edge-rpi-eeprom
}

FILES:${PN} = "${sbindir}/edge-rpi-eeprom"

# rpi-eeprom: the updater + bootloader-2712 payload. raspi-utils: vcgencmd,
# which rpi-eeprom-update reads the current version/config through (via
# /dev/vcio). util-linux: findmnt for the boot-partition guard.
RDEPENDS:${PN} = "rpi-eeprom raspi-utils util-linux coreutils"
