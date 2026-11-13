# uboot-fit boot-chain family: firmware -> U-Boot -> signed per-slot FIT
# verified against the key in U-Boot's control DTB -> raw U-Boot env for
# RAUC's boot-count. Inherited by edge-ab-image when EDGE_BOOT_CHAIN is
# "uboot-fit".

inherit edge-verity-image

# The slot FITs are image-owned outputs and remain in IMGDEPLOYDIR until
# do_image_complete publishes them. WIC accepts absolute IMAGE_BOOT_FILES
# sources; other boot artifacts continue to come from DEPLOY_DIR_IMAGE.
IMAGE_BOOT_FILES = "${IMGDEPLOYDIR}/${EDGE_VERITY_FIT_A};fitImage-A ${IMGDEPLOYDIR}/${EDGE_VERITY_FIT_B};fitImage-B ${EDGE_BOOT_EXTRA}"
do_image_wic[depends] += "${EDGE_BOOT_DEPLOY_DEPS}"

# FIT trust gate on the artifacts: U-Boot verifies only keys marked
# required="conf", so a missing or optional anchor key boots unsigned and
# foreign-signed FITs. After do_image_verity_fit it covers WIC and bundles;
# each slot FIT must verify against the shipped anchor.
EDGE_FIT_TRUSTED_KEYNAMES ?= "${UBOOT_SIGN_KEYNAME}"
EDGE_FIT_GATE = "${EDGE_DISTRO_LAYERDIR}/scripts/edge-fit-gate.py"

do_image_wic[depends] += "u-boot-tools-native:do_populate_sysroot dtc-native:do_populate_sysroot"
do_image_wic[prefuncs] += "edge_check_fit_anchor"
do_image_verity_fit[depends] += "${EDGE_BOOT_DEPLOY_DEPS}"
do_image_verity_fit[postfuncs] += "edge_check_fit_anchor edge_check_slot_fits"
do_image_verity_fit[file-checksums] += "${EDGE_FIT_GATE}:True"

def edge_fit_anchor_path(d):
    import os
    dtb_name = (d.getVar('EDGE_FIT_PUBKEY_DTB') or '').strip()
    if not dtb_name:
        bb.fatal(
            "EDGE_FIT_PUBKEY_DTB is unset while UBOOT_SIGN_ENABLE = '1'.\n"
            "  Set it in conf/machine/include/edge-board-%s.inc to the DTB that\n"
            "  is U-Boot's control FDT at runtime. Without it the FIT would be\n"
            "  signed at build time and unverified at boot."
            % d.getVar('MACHINE'))
    return os.path.join(d.getVar('DEPLOY_DIR_IMAGE'), dtb_name)

def edge_fit_gate(d, args):
    import subprocess
    run = subprocess.run(['python3', d.getVar('EDGE_FIT_GATE')] + args,
                         capture_output=True, text=True)
    if run.returncode != 0:
        bb.fatal("FIT trust gate failed:\n%s" % run.stderr.strip())

python edge_check_fit_anchor() {
    if d.getVar('UBOOT_SIGN_ENABLE') != '1':
        bb.note("UBOOT_SIGN_ENABLE is not 1; FIT trust gate skipped.")
        return
    dtb = edge_fit_anchor_path(d)
    edge_fit_gate(d, ['anchor', '--dtb', dtb,
                      '--keyname', d.getVar('UBOOT_SIGN_KEYNAME'),
                      '--algo', '%s,%s' % (d.getVar('FIT_HASH_ALG'), d.getVar('FIT_SIGN_ALG')),
                      '--bits', d.getVar('FIT_SIGN_NUMBITS'),
                      '--trusted'] + d.getVar('EDGE_FIT_TRUSTED_KEYNAMES').split())
    bb.note("FIT anchor OK: %s" % dtb)
}

python edge_check_slot_fits() {
    import os
    if d.getVar('UBOOT_SIGN_ENABLE') != '1':
        return
    dtb = edge_fit_anchor_path(d)
    for name in (d.getVar('EDGE_VERITY_FIT_A'), d.getVar('EDGE_VERITY_FIT_B')):
        fit = os.path.join(d.getVar('IMGDEPLOYDIR'), name)
        edge_fit_gate(d, ['fit', '--dtb', dtb, '--fit', fit])
        bb.note("slot FIT verifies against the shipped anchor: %s" % name)
}
