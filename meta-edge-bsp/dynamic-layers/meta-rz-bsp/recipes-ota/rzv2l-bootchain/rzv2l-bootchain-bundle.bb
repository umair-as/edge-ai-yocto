SUMMARY     = "Bootloader-only RAUC bundle for the RZ/V2L eMMC boot partitions"
DESCRIPTION = "Signed RAUC bundle carrying BL2 and FIP as one boot-partition image \
for the boot-emmc bootloader slot. Installed by an operator, separately from \
rootfs bundles."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "smarc-rzv2l"

inherit bundle
require recipes-ota/bundles/edge-bundle-crypt.inc

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://rzv2l-bootchain-bundle-hook.sh \
    file://rzv2l-bootchain-compose.py \
"

# Must match rauc-conf-edge.
RAUC_BUNDLE_COMPATIBLE ?= "edge-ai-${MACHINE}"
RAUC_BUNDLE_VERSION     = "${DISTRO_VERSION}"
RAUC_BUNDLE_DESCRIPTION = "RZ/V2L eMMC bootchain (BL2 + FIP) for ${MACHINE}"
RAUC_BUNDLE_BUILD       = "${EDGE_BUILD_ID}"
RAUC_BUNDLE_BUILD[vardepsexclude] = "EDGE_BUILD_ID DATETIME"

RZV2L_BOOTCHAIN_VARIANT = "${@'pmic' if d.getVar('PMIC_SUPPORT') == '1' else 'non-pmic'}"
RZV2L_BOOTCHAIN_SUFFIX  = "${@'_pmic' if d.getVar('PMIC_SUPPORT') == '1' else ''}"
RZV2L_BOOTCHAIN_BL2     = "bl2_bp_mmc-${MACHINE}${RZV2L_BOOTCHAIN_SUFFIX}.bin"
RZV2L_BOOTCHAIN_FIP     = "fip-${MACHINE}${RZV2L_BOOTCHAIN_SUFFIX}.bin"
RZV2L_BOOTCHAIN_IMAGE   = "rzv2l-bootchain-emmc-${MACHINE}.img"
# Major.minor of the TF-A recipe pin; the FIP offset is a property of it.
RZV2L_BOOTCHAIN_TFA_PIN = "${@(__import__('re').match(r'(\d+\.\d+)', d.getVar('PREFERRED_VERSION_trusted-firmware-a') or '') or [None, ''])[1]}"

# firmware-pack's do_deploy produces BL2 and FIP (dependency via bundle.bbclass).
RAUC_BUNDLE_SLOTS = "bootloader"
RAUC_SLOT_bootloader         = "firmware-pack"
RAUC_SLOT_bootloader[type]   = "boot"
RAUC_SLOT_bootloader[file]   = "${RZV2L_BOOTCHAIN_IMAGE}"
# post-install is the read-back check before RAUC flips EXT_CSD; the device's
# pre-install handler refuses a bootloader bundle without both hooks.
RAUC_SLOT_bootloader[hooks]  = "pre-install;post-install"
RAUC_BUNDLE_HOOKS[file]      = "rzv2l-bootchain-bundle-hook.sh"

# Read by the device's pre-install handler as RAUC_META_EDGE_*; the per-part
# sizes and hashes are added by rzv2l_bootchain_compose.
RAUC_META_SECTIONS = "edge"
RAUC_META_edge[bootchain-format] = "rzv2l-emmc-bootpart-v1"
RAUC_META_edge[variant]          = "${RZV2L_BOOTCHAIN_VARIANT}"
RAUC_META_edge[tfa-pin]          = "${RZV2L_BOOTCHAIN_TFA_PIN}"
RAUC_META_edge[build-id]         = "${EDGE_BUILD_ID}"

do_configure[depends] += "dtc-native:do_populate_sysroot"
do_configure[prefuncs] += "rzv2l_bootchain_compose"
do_configure[vardeps] += "EDGE_RZV2L_BOOTCHAIN_BL2_OFFSET EDGE_RZV2L_BOOTCHAIN_FIP_OFFSET \
    EDGE_RZV2L_TFA_FIP_LAYOUT EDGE_RZV2L_BOOTCHAIN_MAX_SIZE RZV2L_BOOTCHAIN_VARIANT \
    RZV2L_BOOTCHAIN_TFA_PIN EDGE_FIT_TRUSTED_KEYNAMES UBOOT_SIGN_KEYNAME"
do_configure[file-checksums] += "${EDGE_DISTRO_LAYERDIR}/scripts/edge-fit-gate.py:True"

python rzv2l_bootchain_compose() {
    import os
    import subprocess

    deploy = d.getVar('DEPLOY_DIR_IMAGE')
    unpack = d.getVar('UNPACKDIR')
    native = d.getVar('STAGING_BINDIR_NATIVE')
    pin = d.getVar('RZV2L_BOOTCHAIN_TFA_PIN')
    if not pin:
        bb.fatal("cannot derive the TF-A pin from PREFERRED_VERSION_trusted-firmware-a")
    anchor = os.path.join(d.getVar('WORKDIR'), 'bootchain-anchor.dtb')
    cmd = ['python3', os.path.join(unpack, 'rzv2l-bootchain-compose.py'),
           '--bl2', os.path.join(deploy, d.getVar('RZV2L_BOOTCHAIN_BL2')),
           '--fip', os.path.join(deploy, d.getVar('RZV2L_BOOTCHAIN_FIP')),
           '--out', os.path.join(unpack, d.getVar('RZV2L_BOOTCHAIN_IMAGE')),
           '--bl2-offset', d.getVar('EDGE_RZV2L_BOOTCHAIN_BL2_OFFSET'),
           '--fip-offset', d.getVar('EDGE_RZV2L_BOOTCHAIN_FIP_OFFSET'),
           '--bootpart-size', d.getVar('EDGE_RZV2L_BOOTCHAIN_MAX_SIZE'),
           '--tfa-pin', pin,
           '--layout', d.getVar('EDGE_RZV2L_TFA_FIP_LAYOUT'),
           '--anchor-out', anchor,
           '--fdtget', os.path.join(native, 'fdtget')]
    run = subprocess.run(cmd, capture_output=True, text=True)
    if run.returncode != 0:
        bb.fatal("bootchain image check failed:\n%s" % run.stderr.strip())
    for line in run.stdout.splitlines():
        key, _, value = line.partition('=')
        d.setVarFlag('RAUC_META_edge', key, value)

    # The FIP's U-Boot DTB is the FIT trust anchor; same gate as the image build.
    env = dict(os.environ, PATH=native + ':' + os.environ.get('PATH', ''))
    gate = subprocess.run(['python3', os.path.join(d.getVar('EDGE_DISTRO_LAYERDIR'), 'scripts', 'edge-fit-gate.py'),
                           'anchor', '--dtb', anchor,
                           '--keyname', d.getVar('UBOOT_SIGN_KEYNAME'),
                           '--algo', '%s,%s' % (d.getVar('FIT_HASH_ALG'), d.getVar('FIT_SIGN_ALG')),
                           '--bits', d.getVar('FIT_SIGN_NUMBITS'),
                           '--trusted'] + (d.getVar('EDGE_FIT_TRUSTED_KEYNAMES') or d.getVar('UBOOT_SIGN_KEYNAME')).split(),
                          capture_output=True, text=True, env=env)
    if gate.returncode != 0:
        bb.fatal("FIT trust gate failed on the bundle FIP's anchor:\n%s" % gate.stderr.strip())
    bb.note("bootchain image %s: %s" % (d.getVar('RZV2L_BOOTCHAIN_IMAGE'), run.stdout.replace('\n', ' ')))
}

BUNDLE_BASENAME = "rzv2l-bootchain-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"
