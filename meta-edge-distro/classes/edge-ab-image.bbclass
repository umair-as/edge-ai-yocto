# A/B-slot image policy. Layers on top of edge-image.bbclass.
#
# Assumes a partition layout with:
#   - shared /boot (slot-specific signed FITs + bootloader-staged assets)
#   - two interchangeable rootfs slots (selected by the OTA backend)
#   - /data for persistent state
#
# This class is OTA-backend-agnostic — slot labels, env init, and confirm-
# boot service all come from edge-ota-${EDGE_OTA_BACKEND}.inc via virtual
# providers and EDGE_SLOT_*_LABEL variables (added in Phase 4 of ADR-0005).
# See ADR-0005 for the full abstraction contract.

inherit edge-image edge-verity-image

# Fail clean at parse if no OTA backend was selected. edge-features.inc
# defaults EDGE_OTA_BACKEND to "rauc"; a build that strips it (or sets it
# empty) gets a SkipRecipe naming the missing piece rather than a confusing
# missing-package error during do_rootfs.
python () {
    if not d.getVar('EDGE_OTA_BACKEND'):
        raise bb.parse.SkipRecipe(
            "edge-ab-image requires EDGE_OTA_BACKEND set (e.g. 'rauc'); "
            "require conf/distro/include/edge-features.inc or set explicitly"
        )
}

# Per-machine boot artifacts. Each kas/machines/<board>.yml supplies
# the values:
#
#   EDGE_BOOT_DTB         — flat DTB consumed by the signed FIT task.
#   EDGE_BOOT_EXTRA       — extra files /boot needs beyond fitImage + DTB.
#                           RZ/V2L uses U-Boot splashload → adds splash.bmp.
#                           Boards that don't do pre-kernel splash leave
#                           this empty.
#   EDGE_BOOT_DEPLOY_DEPS — task-deps that publish bootloader / FIT /
#                           splash artifacts into DEPLOY_DIR_IMAGE before
#                           WIC runs. RZ/V2L's three:
#                             edge-splash-assets:do_deploy
#                             trusted-firmware-a:do_deploy
#                             edge-kernel-fit:do_deploy
#                           A board that doesn't use TF-A or a separate
#                           FIT recipe leaves those out.
#
# Empty defaults let a non-overriding machine reach the explicit FIT-input
# validation instead of failing during variable expansion.
EDGE_BOOT_DTB         ?= ""
EDGE_BOOT_EXTRA       ?= ""
EDGE_BOOT_DEPLOY_DEPS ?= ""

# The slot FITs are image-owned outputs and remain in IMGDEPLOYDIR until
# do_image_complete publishes them. WIC accepts absolute IMAGE_BOOT_FILES
# sources; other boot artifacts continue to come from DEPLOY_DIR_IMAGE.
IMAGE_BOOT_FILES = "${IMGDEPLOYDIR}/${EDGE_VERITY_FIT_A};fitImage-A ${IMGDEPLOYDIR}/${EDGE_VERITY_FIT_B};fitImage-B ${EDGE_BOOT_EXTRA}"
do_image_wic[depends] += "${EDGE_BOOT_DEPLOY_DEPS}"

# Slot labels (EDGE_SLOT_A_LABEL / EDGE_SLOT_B_LABEL) are set by the
# OTA backend include — rauc-tier values come from edge-ota-rauc.inc.
# The __anonymous gate above guarantees that include has been pulled.

# Slot + data partition sizes in MB. Per-machine overrides go in
# kas/machines/<board>.yml — 128 GB SD variants set EDGE_DATA_SIZE_MB
# to fill the card; a smaller carrier shrinks the slot size. WKS .wks.in
# substitution is bitbake-time, so no WICVARS enrolment needed.
EDGE_SLOT_SIZE_MB ?= "4096"
EDGE_DATA_SIZE_MB ?= "1024"

# Boot target — selects the on-disk layout and the /data growth mechanism:
#   esd  — MBR user area, eSD boot (BL2 at sector 0), custom grow-data service.
#   emmc — GPT user area, eMMC boot (BL2 in mmcblk0boot0), systemd-repart.
# Default esd; the eSD path is unchanged when unset. The machine overlay maps
# this to the matching WKS_FILE.
EDGE_BOOT_TARGET ?= "esd"

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
