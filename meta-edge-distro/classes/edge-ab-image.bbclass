# A/B-slot image policy. Layers on top of edge-image.bbclass.
#
# Assumes a partition layout with:
#   - a per-slot boot payload (signed FIT on uboot-fit, UKI on uefi-uki)
#   - two interchangeable rootfs slots (selected by the OTA backend)
#   - /data for persistent state
#
# This class is OTA-backend-agnostic — slot labels and OTA bindings come
# from edge-ota-${EDGE_OTA_BACKEND}.inc via virtual providers and
# EDGE_SLOT_*_LABEL variables. See ADR-0005 for the abstraction contract.

inherit edge-image

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

# Per-machine boot artifacts (uboot-fit boards). Each
# conf/machine/include/edge-board-<MACHINE>.inc supplies the values:
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

# Slot labels (EDGE_SLOT_A_LABEL / EDGE_SLOT_B_LABEL) are set by the
# OTA backend include — rauc-tier values come from edge-ota-rauc.inc.
# The __anonymous gate above guarantees that include has been pulled.

# Slot + data partition sizes in MB. Per-machine overrides go in the board
# include (edge-board-ventuno-q.inc sets an 8 GiB slot). WKS .wks.in
# substitution is bitbake-time, so no WICVARS enrolment needed.
EDGE_SLOT_SIZE_MB ?= "4096"
EDGE_DATA_SIZE_MB ?= "1024"

# Boot target, selected with LAYOUT=esd|emmc (kas/boot/emmc.yml):
#   esd  — MBR user area, eSD boot (BL2 at sector 0).
#   emmc — GPT user area, eMMC boot (BL2 in mmcblk0boot0).
# The board include maps it to WKS_FILE and EDGE_PTABLE. Default esd.
EDGE_BOOT_TARGET ?= "esd"

# Boot-chain family: payload, trust gate and install artifacts
# (edge-ab-uboot-fit.bbclass, edge-ab-uefi-uki.bbclass). An unknown
# family inherits nothing here and fails at edge-image.bbclass's gate.
inherit ${@'edge-ab-' + d.getVar('EDGE_BOOT_CHAIN') if d.getVar('EDGE_BOOT_CHAIN') in ('uboot-fit', 'uefi-uki') else ''}
