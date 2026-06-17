FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# TF-A overlay for the edge platform.
# Version line selected via kas/trusted-firmware-a/renesas-cip-2.10.yml.

# meta-renesas's _2.10.bb sets S = "${WORKDIR}/git", which wrynose's
# do_unpack rejects. Override here (not via kas-patch) to survive bumps.
S = "${UNPACKDIR}/${BP}"

# S override invalidates the upstream LIC_FILES_CHKSUM path; re-point.
LIC_FILES_CHKSUM = "file://docs/license.rst;md5=b2c740efedc159745b9b31f88ff03dde"

# Renesas CIP fork. Mainline plat/renesas/rzg/ is R-Car (G1/G2) only and
# has no RZ/V2L support; the CIP fork carries plat/renesas/rz/common/
# where RZ/V2L + RZ/G2L share BL2.
SRC_URI = "git://github.com/renesas-rz/rzg_trusted-firmware-a.git;protocol=https;name=tfa;nobranch=1"
SRCREV_tfa = "f59ed5a31ef6b28200e9ba35fc78a607fdeda6dd"
COMPATIBLE_MACHINE = "(rzg2h-family|rzg2l-family)"

SRC_URI:append = " \
    file://0001-rz-common-bl2-parse-optee-header-for-BL32.patch \
    file://0002-bl2-add-build-tag-banner.patch \
"

# Deterministic build tag visible on serial immediately after BL2 platform
# setup. Override EDGE_BUILD_PROFILE per-build to record provenance.
EDGE_BUILD_PROFILE ?= "local"
EDGE_BUILD_TAG     ?= "edge-${EDGE_BUILD_PROFILE}"
EXTRA_OEMAKE:append = " CFLAGS=\"-DBUILD_TAG=\\\"${EDGE_BUILD_TAG}\\\"\""

# OP-TEE as BL32. The TF-A FIP packs the OP-TEE Trusted OS via the SPD
# (Secure Payload Dispatcher). meta-arm consumes TFA_SPD; BL32 path is
# passed through EXTRA_OEMAKE.
ENABLE_SPD_OPTEE                          ?= "0"
ENABLE_SPD_OPTEE:smarc-rzv2l              ?= "1"
TFA_SPD:smarc-rzv2l = "${@oe.utils.conditional('ENABLE_SPD_OPTEE', '1', 'opteed', '', d)}"
# Mainline meta-arm provides optee-os. meta-edge-bsp/recipes-security/
# optee/optee-os_%.bbappend wires it for the rz/g2l_smarc_2 platform.
DEPENDS:append      = " ${@oe.utils.conditional('ENABLE_SPD_OPTEE', '1', ' optee-os',    '', d)}"
EXTRA_OEMAKE:append:smarc-rzv2l = " ${@oe.utils.conditional('ENABLE_SPD_OPTEE', '1', 'BL32=${RECIPE_SYSROOT}/boot/tee-${MACHINE}.bin', '', d)}"

# meta-arm's TF-A consumes BL33 from ${DEPLOY_DIR_IMAGE}/u-boot.bin without
# declaring a file-checksum dep — partial task flows can leave the FIP
# carrying a stale BL33.
do_compile[file-checksums] += "${DEPLOY_DIR_IMAGE}/u-boot.bin:True"

# bp_esd + fip_pmic deploy is owned by meta-renesas's firmware-pack.bb.

# PMIC variant bridge. meta-renesas's _2.10.bb installs bl2/bl31/fip _pmic
# variants to legacy /firmware/, but firmware.bbclass's SYSROOT_DIRS only
# exposes ${FIRMWARE_DIR}, so firmware-pack reads from a path that doesn't
# have them and do_rootfs QA fires installed-vs-shipped. Mirror _pmic into
# FIRMWARE_DIR; claim the originals in FILES:${PN} so QA passes and
# meta-renesas's do_deploy:append (which cp's from /firmware/) still works.
do_install:append:rzg2l-family() {
    if [ "${PMIC_SUPPORT}" = "1" ]; then
        install -d ${D}${FIRMWARE_DIR}
        cp -p ${D}/firmware/bl2-${TFA_PLATFORM}_pmic.bin   ${D}${FIRMWARE_DIR}/
        cp -p ${D}/firmware/bl31-${TFA_PLATFORM}_pmic.bin  ${D}${FIRMWARE_DIR}/
        cp -p ${D}/firmware/fip-${TFA_PLATFORM}_pmic.bin   ${D}${FIRMWARE_DIR}/
    fi
}

FILES:${PN}:append:rzg2l-family = " \
    /firmware/bl2-${TFA_PLATFORM}_pmic.bin \
    /firmware/bl31-${TFA_PLATFORM}_pmic.bin \
    /firmware/fip-${TFA_PLATFORM}_pmic.bin \
"
