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

# FIT trust anchor, asserted on the artifact rather than assumed from config.
#
# UBOOT_SIGN_ENABLE = "1" only requests signing. The public key reaches
# U-Boot's control FDT through board-specific wiring (concat_dtb on RZ/V2L,
# fdt_add_pubkey on RPi5); without it the slot FITs are signed but boot
# unverified. This checks the deployed DTB carries the signing key.
do_image_wic[depends] += "u-boot-tools-native:do_populate_sysroot dtc-native:do_populate_sysroot"
do_image_wic[prefuncs] += "edge_check_fit_anchor"

python edge_check_fit_anchor() {
    import subprocess, os
    if d.getVar('UBOOT_SIGN_ENABLE') != '1':
        bb.note("UBOOT_SIGN_ENABLE is not 1; FIT anchor check skipped.")
        return

    dtb_name = (d.getVar('EDGE_FIT_PUBKEY_DTB') or '').strip()
    if not dtb_name:
        bb.fatal(
            "EDGE_FIT_PUBKEY_DTB is unset while UBOOT_SIGN_ENABLE = '1'.\n"
            "  Set it in conf/machine/include/edge-board-%s.inc to the DTB that\n"
            "  is U-Boot's control FDT at runtime. Without it the FIT would be\n"
            "  signed at build time and unverified at boot."
            % d.getVar('MACHINE'))

    deploy = d.getVar('DEPLOY_DIR_IMAGE')
    dtb = os.path.join(deploy, dtb_name)
    if not os.path.exists(dtb):
        bb.fatal("FIT anchor DTB not deployed: %s\n"
                 "  EDGE_FIT_PUBKEY_DTB names it; nothing produced it." % dtb)

    keyname = d.getVar('UBOOT_SIGN_KEYNAME')
    want = "%s,%s" % (d.getVar('FIT_HASH_ALG'), d.getVar('FIT_SIGN_ALG'))
    node = "/signature/key-%s" % keyname
    try:
        got = subprocess.check_output(
            ['fdtget', dtb, node, 'algo'], stderr=subprocess.STDOUT).decode().strip()
    except subprocess.CalledProcessError as e:
        bb.fatal(
            "No FIT verification key in the deployed control DTB.\n"
            "  DTB:  %s\n"
            "  Node: %s (from UBOOT_SIGN_KEYNAME)\n"
            "  fdtget: %s\n"
            "  UBOOT_SIGN_ENABLE = '1', so the slot FITs are signed -- but with\n"
            "  no key in the control FDT U-Boot cannot verify them and boots\n"
            "  them unverified. The key injection is board-specific wiring in\n"
            "  the U-Boot or kernel recipe, and it did not run for this board."
            % (dtb, node, e.output.decode().strip()))
    if got != want:
        bb.fatal("FIT anchor algo mismatch in %s %s: got '%s', expected '%s'"
                 % (dtb, node, got, want))
    bb.note("FIT anchor OK: %s carries %s (%s)" % (dtb_name, node, got))
}
