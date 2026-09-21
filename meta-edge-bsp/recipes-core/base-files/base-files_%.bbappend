FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# /data mountpoint must exist in the rootfs image: the dm-verity root is
# immutable, so systemd cannot create it at mount time and the fstab /data
# entry fails, taking every /data-dependent unit down with it.
# /boot is already in base-files' stock dirs755.
dirs755:append = " /data"

# hostname overrides the auto-derived one (OE-Core sets ${MACHINE}, i.e.
# "smarc-rzv2l") with a brand-aligned default; a machine inherits it unless it
# overrides per-machine. fstab is per board: files/<machine>/fstab is selected
# by the MACHINE override, files/fstab is the default.
SRC_URI += " \
    file://hostname \
    file://hosts \
    file://fstab \
"

do_install:append() {
    install -m 0644 ${UNPACKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${UNPACKDIR}/hosts    ${D}${sysconfdir}/hosts
    # Adds the boot and data mounts so systemd-fstab-generator creates the
    # matching .mount units; edge-persistence's binds and the identity-persist
    # services skip on ConditionPathIsMountPoint=/data without them.
    install -m 0644 ${UNPACKDIR}/fstab    ${D}${sysconfdir}/fstab
}
