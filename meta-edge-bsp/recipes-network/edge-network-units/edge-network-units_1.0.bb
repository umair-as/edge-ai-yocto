SUMMARY     = "systemd-networkd .network units, generated from board facts"
DESCRIPTION = "Generates one Unmanaged=yes unit per interface in \
EDGE_UNMANAGED_IFACES and a DHCP uplink unit for EDGE_UPLINK_IFACE. Interface \
roles are board facts, so the units are templated rather than shipped."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/network"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://uplink.network.in \
    file://unmanaged.network.in \
"

# Installs interface names read from the board include, so the output is
# machine-specific and the recipe cannot be allarch.
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = "systemd-networkd"

S = "${UNPACKDIR}"

# An interface reserved from systemd-networkd. On a board that netboots, the
# kernel's ip=dhcp NFS-root path owns its interface and networkd must not
# touch it. Empty is a valid value -- a board that manages every interface
# ships no unmanaged unit -- so this one is not fail-closed.
EDGE_UNMANAGED_IFACES ??= ""
# The DHCP uplink. Required: the unit is named after it.
EDGE_UPLINK_IFACE ??= ""

do_install() {
    uplink="${EDGE_UPLINK_IFACE}"
    if [ -z "$uplink" ]; then
        bbfatal "EDGE_UPLINK_IFACE is empty. Set it in \
conf/machine/include/edge-board-${MACHINE}.inc -- the DHCP uplink unit is \
named after the interface and cannot be guessed."
    fi

    install -d ${D}${sysconfdir}/systemd/network

    sed -e 's|@EDGE_UPLINK_IFACE@|'"$uplink"'|g' \
        ${UNPACKDIR}/uplink.network.in \
        > ${D}${sysconfdir}/systemd/network/10-${uplink}.network
    chmod 0644 ${D}${sysconfdir}/systemd/network/10-${uplink}.network

    for iface in ${EDGE_UNMANAGED_IFACES}; do
        sed -e 's|@IFACE@|'"$iface"'|g' \
            ${UNPACKDIR}/unmanaged.network.in \
            > ${D}${sysconfdir}/systemd/network/10-${iface}.network
        chmod 0644 ${D}${sysconfdir}/systemd/network/10-${iface}.network
    done

    # Fail closed on an unexpanded token rather than shipping a unit that
    # systemd-networkd silently ignores.
    if grep -l '@[A-Z_]*@' ${D}${sysconfdir}/systemd/network/*.network; then
        bbfatal "Unexpanded @TOKEN@ left in a generated .network unit"
    fi
}

do_install[vardeps] += "EDGE_UNMANAGED_IFACES EDGE_UPLINK_IFACE"

FILES:${PN}     = "${sysconfdir}/systemd/network/*.network"
CONFFILES:${PN} = "${sysconfdir}/systemd/network/*.network"
