SUMMARY     = "udev rules and group for user-space I/O device access"
DESCRIPTION = "Creates the gpio system group and installs the udev rule that \
gives it 0660 access to the GPIO character devices, so a member can drive \
header GPIO through libgpiod without root."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://70-edge-io.rules"

inherit allarch useradd

S = "${UNPACKDIR}"

# The group is created here, with the rule that names it: udevd resolves
# every literal GROUP= in its rules at start (resolve-names=early), and a
# name /etc/group lacks goes to nss-systemd and systemd-userdbd instead.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system gpio"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/70-edge-io.rules ${D}${sysconfdir}/udev/rules.d/
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/70-edge-io.rules"

RDEPENDS:${PN} = "udev"
