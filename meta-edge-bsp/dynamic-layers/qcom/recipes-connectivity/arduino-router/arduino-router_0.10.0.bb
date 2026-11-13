SUMMARY     = "MessagePack RPC router between Linux and the board MCU"
DESCRIPTION = "Routes MessagePack RPC calls between local clients on a Unix \
socket and the STM32 MCU on its USB serial link, with the VENTUNO Q unit \
drop-in and the udev rule that names the MCU port /dev/ttySTM0."
HOMEPAGE    = "https://github.com/arduino/arduino-router"
SECTION     = "console/utils"
LICENSE     = "GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://src/${GO_IMPORT}/LICENSE.txt;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = " \
    git://${GO_IMPORT};protocol=https;nobranch=1;destsuffix=${GO_SRCURI_DESTSUFFIX} \
    file://10-ventuno-q.conf \
    file://99-arduino-stm-tty.rules \
"
# v0.10.0
SRCREV = "b92ba75a62781a7b79d4bc0429a499542f939233"

UPSTREAM_CHECK_GITTAGREGEX = "v(?P<pver>\d+(\.\d+)+)$"

require ${BPN}-licenses.inc
require ${BPN}-go-mods.inc

GO_IMPORT  = "github.com/arduino/arduino-router"
GO_INSTALL = "${GO_IMPORT} ${GO_IMPORT}/cmd/arduino-router-cli"

COMPATIBLE_MACHINE = "ventuno-q"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit go-mod go-mod-update-modules systemd

CGO_ENABLED = "0"
GO_LINKSHARED = ""
GO_EXTRA_LDFLAGS = "-X main.Version=${PV}"

RDEPENDS:${PN} = "libgpiod-tools"

do_install:append() {
    install -Dm 0644 ${S}/src/${GO_IMPORT}/debian/arduino-router/etc/systemd/system/arduino-router.service \
        ${D}${systemd_system_unitdir}/arduino-router.service
    install -Dm 0644 ${UNPACKDIR}/10-ventuno-q.conf \
        ${D}${systemd_system_unitdir}/arduino-router.service.d/10-ventuno-q.conf
    install -Dm 0644 ${UNPACKDIR}/99-arduino-stm-tty.rules \
        ${D}${nonarch_base_libdir}/udev/rules.d/99-arduino-stm-tty.rules

    # Upstream CI helpers (bash) in the -dev source copy.
    rm -rf ${D}${libdir}/go/src/${GO_IMPORT}/scripts
}

SYSTEMD_SERVICE:${PN} = "arduino-router.service"

FILES:${PN} += " \
    ${systemd_system_unitdir}/arduino-router.service.d \
    ${nonarch_base_libdir}/udev/rules.d \
"
