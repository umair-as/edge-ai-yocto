SUMMARY     = "systemd-networkd .network units for eth0 and eth1"
DESCRIPTION = "Provides eth1 DHCP (v4+v6) configuration and an eth0 unmanaged \
declaration for systemd-networkd. eth0 is left unmanaged so the kernel's \
ip=dhcp NFS-root path is not disrupted on netboot; eth1 is the uplink."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/network"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://10-eth1.network \
    file://10-eth0.network \
"

inherit allarch

RDEPENDS:${PN} = "systemd-networkd"

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/10-eth1.network ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${UNPACKDIR}/10-eth0.network ${D}${sysconfdir}/systemd/network/
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/network/10-eth1.network \
    ${sysconfdir}/systemd/network/10-eth0.network \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/systemd/network/10-eth1.network \
    ${sysconfdir}/systemd/network/10-eth0.network \
"
