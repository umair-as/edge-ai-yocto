SUMMARY     = "Default NetworkManager profiles + conf.d drop-ins"
DESCRIPTION = "Stages an eth0 DHCP profile and NM conf.d drop-ins (DNS \
handling, no MAC randomization, no interface renaming). A oneshot activates \
a runtime eth0-unmanaged drop-in when root=/dev/nfs is on the cmdline."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/network"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://eth0-dhcp.nmconnection \
    file://10-edge-defaults.conf \
    file://90-netboot-unmanaged.conf \
    file://edge-netboot-nm-unmanage.service \
"

inherit allarch systemd

S = "${UNPACKDIR}"

# RDEPENDS on networkmanager so this recipe can't ship into an image
# that doesn't have NM (would silently leave dead config files).
RDEPENDS:${PN} = "networkmanager"

SYSTEMD_SERVICE:${PN}      = "edge-netboot-nm-unmanage.service"
SYSTEMD_AUTO_ENABLE:${PN}  = "enable"

do_install() {
    # System connections must be 0600 root:root or NM refuses to load
    # them. Use install -D so the parent dirs are created implicitly —
    # Do NOT `install -d` the system-connections dir: networkmanager-daemon
    # already owns /etc/NetworkManager/; a second claim triggers an RPM
    # transaction conflict at do_rootfs. NM owns the directory mode.
    install -D -m 0600 ${UNPACKDIR}/eth0-dhcp.nmconnection \
        ${D}${sysconfdir}/NetworkManager/system-connections/eth0-dhcp.nmconnection

    install -d ${D}${sysconfdir}/NetworkManager/conf.d
    install -m 0644 ${UNPACKDIR}/10-edge-defaults.conf \
        ${D}${sysconfdir}/NetworkManager/conf.d/10-edge-defaults.conf

    # Netboot drop-in lands OUTSIDE NM's /etc scan path. The companion
    # systemd unit symlinks it into /run/NetworkManager/conf.d/ at boot
    # only when ConditionKernelCommandLine=root=/dev/nfs matches.
    install -D -m 0644 ${UNPACKDIR}/90-netboot-unmanaged.conf \
        ${D}${datadir}/edge-network-profiles/90-netboot-unmanaged.conf

    install -D -m 0644 ${UNPACKDIR}/edge-netboot-nm-unmanage.service \
        ${D}${systemd_system_unitdir}/edge-netboot-nm-unmanage.service
}

FILES:${PN} = " \
    ${sysconfdir}/NetworkManager/system-connections/eth0-dhcp.nmconnection \
    ${sysconfdir}/NetworkManager/conf.d/10-edge-defaults.conf \
    ${datadir}/edge-network-profiles/90-netboot-unmanaged.conf \
    ${systemd_system_unitdir}/edge-netboot-nm-unmanage.service \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/NetworkManager/system-connections/eth0-dhcp.nmconnection \
    ${sysconfdir}/NetworkManager/conf.d/10-edge-defaults.conf \
"
