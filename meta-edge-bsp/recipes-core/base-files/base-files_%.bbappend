FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# Override the auto-derived hostname (which OE-Core sets to ${MACHINE}, i.e.
# "smarc-rzv2l") with a brand-aligned default. Other machines added to this
# distro inherit the same hostname unless they override per-machine.
SRC_URI += " \
    file://hostname \
    file://hosts \
"

do_install:append() {
    install -m 0644 ${UNPACKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${UNPACKDIR}/hosts    ${D}${sysconfdir}/hosts
}
