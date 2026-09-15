inherit kernel
require recipes-kernel/linux/linux-yocto.inc

SUMMARY     = "Mainline stable Linux 6.18 for the Raspberry Pi 5"
DESCRIPTION = "kernel.org linux-6.18.y pinned to a released tag, built from the \
arm64 defconfig plus the edge-ai kernel policy fragments, with the BCM2712 \
enablement patches mainline lacks (firmware RTC, AVS thermal zone, ramoops)."
HOMEPAGE    = "https://www.kernel.org/"
BUGTRACKER  = "https://bugzilla.kernel.org/"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

# CVE identity. kernel.bbclass defaults CVE_PRODUCT to "linux_kernel
# linux:linux"; the second token over-matches unrelated NVD products. PV's
# "+git" suffix breaks version-range comparison, so the clean release goes in.
CVE_PRODUCT = "linux_kernel"
CVE_VERSION = "${LINUX_VERSION}"
RECIPE_NO_UPDATE_REASON = "Pinned to a linux-6.18.y tag; bump SRCREV_machine and LINUX_VERSION together"

COMPATIBLE_MACHINE = "^raspberrypi5$"

LINUX_VERSION = "6.18.52"
LINUX_VERSION_EXTENSION = ""
PV = "${LINUX_VERSION}+git"

KBRANCH = "linux-6.18.y"
KMETA = "kernel-meta"
# v6.18.52
SRCREV_machine = "8f3741e6feb045da5b406df0a80b42a1adfb289b"
# yocto-kernel-cache yocto-6.18, the revision oe-core's linux-yocto_6.18 pins
# at the layer pin. Only the tooling side is used: no KERNEL_FEATURES are
# taken from it.
SRCREV_meta = "2f71b0a288c307062fc60948ac793d8d51c685e2"
SRCREV_FORMAT = "machine_meta"

SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;name=machine;branch=${KBRANCH};protocol=https \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.18;destsuffix=${KMETA};protocol=https \
"

# arm64 defconfig as the base; the policy and board fragments are merged on
# top by do_kernel_configme.
KCONFIG_MODE = "--alldefconfig"
KBUILD_DEFCONFIG = "defconfig"

# Platform floor: fragments, the resolved-.config assertion, dev toggles.
require ${EDGE_BSP_LAYERDIR}/recipes-kernel/linux/edge-kernel-policy.inc

# Board content. The RTC driver and its DT node are backports of the
# raspberrypi/linux firmware RTC; the AVS thermal zone is pending upstream;
# the ramoops region pairs with pstore-persist.cfg in the policy set.
# pcie-rpi5.cfg builds the PCIe host bridge in (RP1 sits behind it);
# boot-devices-rpi5.cfg builds the SD host in (the dm-verity root cannot
# wait for a module). wireless-rpi5.cfg comes after the policy fragments
# on purpose: later fragments win the merge, and it re-enables the 802.11
# stack security-hardening.cfg turns off for boards without a radio.
SRC_URI:append = " \
    file://patches/0001-rtc-rtc-rpi-add-simple-RTC-driver-for-Raspberry-Pi.patch \
    file://patches/0002-arm64-dts-broadcom-bcm2712-add-rpi-rtc-node.patch \
    file://patches/0003-arm64-dts-broadcom-bcm2712-add-avs-thermal-zone.patch \
    file://patches/0004-arm64-dts-broadcom-bcm2712-rpi-5-b-add-ramoops-reserved-memory.patch \
    file://cfg/boot-devices-rpi5.cfg \
    file://cfg/pcie-rpi5.cfg \
    file://cfg/thermal-rpi5.cfg \
    file://cfg/rtc-rpi.cfg \
    file://cfg/wireless-rpi5.cfg \
"

# Asserted with the platform symbols: a modular SD host or PCIe bridge is a
# green build whose root device or network appears too late.
EDGE_KERNEL_POLICY_EXTRA_CONFIG = "CONFIG_MMC_SDHCI_BRCMSTB=y CONFIG_PCIE_BRCMSTB=y"

# FIT trust anchor. U-Boot on this board takes its control FDT from the
# firmware, which loads the board DTB this recipe deploys, so the FIT public
# key goes into that DTB here. fdt_add_pubkey writes the same
# /signature/key-<name> node mkimage -K does, from the certificate alone.
# edge_check_fit_anchor (edge-ab-image.bbclass) verifies the deployed file
# before the image is assembled.
DEPENDS += "u-boot-tools-native"
UBOOT_FDT_ADD_PUBKEY ?= "${STAGING_BINDIR_NATIVE}/fdt_add_pubkey"

do_deploy[depends] += "${@'kernel-signing-keys-native:do_compile' if d.getVar('FIT_GENERATE_KEYS') == '1' else ''}"
do_deploy[file-checksums] += "${@'${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt:True' if d.getVar('UBOOT_SIGN_ENABLE') == '1' else ''}"

do_deploy:append() {
    if [ "${UBOOT_SIGN_ENABLE}" != "1" ]; then
        bbnote "UBOOT_SIGN_ENABLE is not 1; no FIT key injected into the board DTB."
        return 0
    fi
    [ -n "${EDGE_FIT_PUBKEY_DTB}" ] || bbfatal "EDGE_FIT_PUBKEY_DTB is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
    deployDir="${DEPLOYDIR}"
    if [ -n "${KERNEL_DEPLOYSUBDIR}" ]; then
        deployDir="${DEPLOYDIR}/${KERNEL_DEPLOYSUBDIR}"
    fi
    dtb="${deployDir}/${EDGE_FIT_PUBKEY_DTB}"
    [ -f "$dtb" ] || bbfatal "FIT anchor DTB ${EDGE_FIT_PUBKEY_DTB} is not among this kernel's deployed DTBs (KERNEL_DEVICETREE = ${KERNEL_DEVICETREE})"
    cert="${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt"
    [ -f "$cert" ] || bbfatal "FIT signing certificate not found: $cert"
    [ -x "${UBOOT_FDT_ADD_PUBKEY}" ] || bbfatal "fdt_add_pubkey not found at ${UBOOT_FDT_ADD_PUBKEY}; the u-boot-tools bbappend installs it"
    ${UBOOT_FDT_ADD_PUBKEY} \
        -a "${FIT_HASH_ALG},${FIT_SIGN_ALG}" \
        -k "${UBOOT_SIGN_KEYDIR}" \
        -n "${UBOOT_SIGN_KEYNAME}" \
        -r conf \
        "$dtb"
    bbnote "FIT public key ${UBOOT_SIGN_KEYNAME} (${FIT_HASH_ALG},${FIT_SIGN_ALG}) injected into ${EDGE_FIT_PUBKEY_DTB}"
}
