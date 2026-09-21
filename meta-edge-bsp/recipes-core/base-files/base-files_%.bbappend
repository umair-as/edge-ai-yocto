FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# /data mountpoint must exist in the rootfs image: the dm-verity root is
# immutable, so systemd cannot create it at mount time and the fstab /data
# entry fails, taking every /data-dependent unit down with it.
# /boot is already in base-files' stock dirs755.
dirs755:append = " /data"

# The board include sets EDGE_HOSTNAME; a board without one gets "edge".
# OE-Core would derive ${MACHINE} (e.g. "smarc-rzv2l"). fstab is per board:
# files/<machine>/fstab is selected by the MACHINE override, files/fstab is
# the default.
EDGE_HOSTNAME ?= "edge"

SRC_URI += " \
    file://hosts \
    file://fstab \
"

do_install:append() {
    # The 127.0.1.1 entry must name the same host as /etc/hostname.
    echo "${EDGE_HOSTNAME}" > ${D}${sysconfdir}/hostname
    sed -e "s|@EDGE_HOSTNAME@|${EDGE_HOSTNAME}|g" ${UNPACKDIR}/hosts > ${D}${sysconfdir}/hosts
    chmod 0644 ${D}${sysconfdir}/hostname ${D}${sysconfdir}/hosts
    # Adds the boot and data mounts so systemd-fstab-generator creates the
    # matching .mount units; edge-persistence's binds and the identity-persist
    # services skip on ConditionPathIsMountPoint=/data without them.
    install -m 0644 ${UNPACKDIR}/fstab    ${D}${sysconfdir}/fstab
}
