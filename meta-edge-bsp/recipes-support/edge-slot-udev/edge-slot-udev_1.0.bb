SUMMARY = "Stable RAUC slot udev symlinks for the edge-ai distro"
DESCRIPTION = "Provides /dev/disk/by-rauc-slot/{boot,rootfsA,rootfsB,data} \
symlinks based on partition identity (mmcblk0pN on MBR, GPT PARTLABEL on the \
emmc target). This avoids slot lookup failures if ext4 labels change during OTA writes."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "base"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://99-edge-rauc-slots.rules.in \
    file://99-edge-rauc-slots-gpt.rules \
"

# The MBR ruleset installs device names read from the board include.
PACKAGE_ARCH = "${MACHINE_ARCH}"

S = "${UNPACKDIR}"

# Boot target picks the rule keying: esd/MBR has no PARTLABEL so it keys on
# mmcblk0pN; emmc/GPT keys on ID_PART_ENTRY_NAME. Both install to the same
# filename so FILES and the RAUC by-rauc-slot devices are identical.
do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    if [ "${EDGE_BOOT_TARGET}" = "emmc" ]; then
        # GPT keys on ID_PART_ENTRY_NAME, which is layout identity rather than
        # a device name, so this branch needs no board facts and must not fail
        # when they are unset.
        install -m 0644 ${UNPACKDIR}/99-edge-rauc-slots-gpt.rules \
            ${D}${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules
    else
        # MBR has no partition identity, so the rules key on device names,
        # which are board facts. udev's KERNEL== matches the kernel device
        # name, so strip the /dev/ prefix the board include carries.
        # Checked one by one, not in a loop: bitbake expands ${VAR} when it
        # generates this script, so shell indirection over variable names
        # would test names the shell never had.
        [ -n "${EDGE_BOOT_DEVICE}" ]   || bbfatal "EDGE_BOOT_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
        [ -n "${EDGE_SLOT_A_DEVICE}" ] || bbfatal "EDGE_SLOT_A_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
        [ -n "${EDGE_SLOT_B_DEVICE}" ] || bbfatal "EDGE_SLOT_B_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
        [ -n "${EDGE_DATA_DEVICE}" ]   || bbfatal "EDGE_DATA_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
        sed -e 's|@EDGE_BOOT_DEVICE@|'"$(basename ${EDGE_BOOT_DEVICE})"'|g' \
            -e 's|@EDGE_SLOT_A_DEVICE@|'"$(basename ${EDGE_SLOT_A_DEVICE})"'|g' \
            -e 's|@EDGE_SLOT_B_DEVICE@|'"$(basename ${EDGE_SLOT_B_DEVICE})"'|g' \
            -e 's|@EDGE_DATA_DEVICE@|'"$(basename ${EDGE_DATA_DEVICE})"'|g' \
            ${UNPACKDIR}/99-edge-rauc-slots.rules.in \
            > ${D}${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules
        chmod 0644 ${D}${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules
        if grep -q '@[A-Z_]*@' ${D}${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules; then
            bbfatal "Unexpanded @TOKEN@ left in 99-edge-rauc-slots.rules"
        fi
    fi
}

do_install[vardeps] += "EDGE_BOOT_DEVICE EDGE_SLOT_A_DEVICE EDGE_SLOT_B_DEVICE \
                        EDGE_DATA_DEVICE EDGE_BOOT_TARGET"

FILES:${PN} = "${sysconfdir}/udev/rules.d/99-edge-rauc-slots.rules"

RDEPENDS:${PN} = "udev"
