SUMMARY = "Stable /dev/leds/builtin names for the VENTUNO Q RGB LEDs"
DESCRIPTION = "udev rule linking the four MCU-driven RGB LEDs (multicolor devices \
stm-led-1..4) to /dev/leds/builtin/led1..led4, the directory the vendor image \
uses for its per-channel LED links."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "base"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://70-edge-ventunoq-leds.rules"

COMPATIBLE_MACHINE = "ventuno-q"

inherit allarch

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/70-edge-ventunoq-leds.rules \
        ${D}${sysconfdir}/udev/rules.d/70-edge-ventunoq-leds.rules
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/70-edge-ventunoq-leds.rules"

RDEPENDS:${PN} = "udev"
