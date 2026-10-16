SUMMARY     = "RAUC guards for the RZ/V2L eMMC bootloader slot"
DESCRIPTION = "RAUC pre-install handler, bootloader slot hooks and the operator \
authorization tool that gate bootchain bundles for the boot-emmc slot on an \
eMMC-booted RZ/V2L."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "bootloaders"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "smarc-rzv2l"
PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = " \
    file://rzv2l-bootchain-common.sh \
    file://rzv2l-bootchain-preinstall \
    file://rzv2l-bootchain-slot-hook \
    file://rzv2l-bootchain-authorize \
    file://rzv2l-bootchain-bundle-hook.sh \
"
S = "${UNPACKDIR}"

RDEPENDS:${PN} = "bash coreutils util-linux-blockdev mmc-utils dtc grep gawk rauc"

do_install() {
    install -d ${D}${nonarch_libdir}/rzv2l-bootchain ${D}${sbindir} ${D}${datadir}/rzv2l-bootchain
    sed -e "s|@MMC_DEV@|${EDGE_RZV2L_BOOTCHAIN_MMC_DEV}|" \
        -e "s|@BL2_OFFSET@|${EDGE_RZV2L_BOOTCHAIN_BL2_OFFSET}|" \
        -e "s|@FIP_OFFSET@|${EDGE_RZV2L_BOOTCHAIN_FIP_OFFSET}|" \
        -e "s|@TFA_FIP_LAYOUT@|${EDGE_RZV2L_TFA_FIP_LAYOUT}|" \
        ${S}/rzv2l-bootchain-common.sh > ${D}${nonarch_libdir}/rzv2l-bootchain/common.sh
    if grep -q '@[A-Z_]*@' ${D}${nonarch_libdir}/rzv2l-bootchain/common.sh; then
        bbfatal "unexpanded @TOKEN@ in common.sh; set the EDGE_RZV2L_BOOTCHAIN_* board facts"
    fi
    install -m 0755 ${S}/rzv2l-bootchain-preinstall ${D}${nonarch_libdir}/rzv2l-bootchain/preinstall
    install -m 0755 ${S}/rzv2l-bootchain-slot-hook ${D}${nonarch_libdir}/rzv2l-bootchain/slot-hook
    install -m 0755 ${S}/rzv2l-bootchain-authorize ${D}${sbindir}/rzv2l-bootchain-authorize
    # Reference copy the pre-install handler compares the bundle hook against;
    # the bundle recipe ships the same file.
    install -m 0644 ${S}/rzv2l-bootchain-bundle-hook.sh ${D}${datadir}/rzv2l-bootchain/bundle-hook.sh
}
do_install[vardeps] += "EDGE_RZV2L_BOOTCHAIN_MMC_DEV EDGE_RZV2L_BOOTCHAIN_BL2_OFFSET \
    EDGE_RZV2L_BOOTCHAIN_FIP_OFFSET EDGE_RZV2L_TFA_FIP_LAYOUT"

FILES:${PN} = "${nonarch_libdir}/rzv2l-bootchain ${sbindir}/rzv2l-bootchain-authorize ${datadir}/rzv2l-bootchain"
