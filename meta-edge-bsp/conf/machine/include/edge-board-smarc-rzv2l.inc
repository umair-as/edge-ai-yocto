# Board facts for the Renesas RZ/V2L SMARC EVK, consumed by the distro's
# board contracts. One file per board; adding a machine adds a file here.
#
# Pulled in by MACHINE name from edge-ai.conf. A missing file is silent in
# bitbake (a failed soft include logs at debug2 only), so EDGE_BOARD_INC is
# the sentinel that turns absence into a readable parse failure.
#
# Assignments are `?=` so an operator override in local.conf scope
# (kas/local.yml) still wins -- this file parses at distro-conf scope, which
# is *after* local.conf. The exceptions are marked: values that must beat the
# vendor machine conf use plain `=`, which is safe because this file also
# parses after conf/machine/${MACHINE}.conf.

EDGE_BOARD_INC = "1"

# --- Accelerator ---------------------------------------------------------
# DRP-AI is RZ/V2L-only SoC IP. This is the allowlist for the machine, not
# the selection; the selection is EDGE_ACCEL from kas/accel/<name>.yml.
# Plain `=`, not `?=`: edge-features.inc declares EDGE_ACCEL_SUPPORTED ?= ""
# and is required before this file, so a `?=` here would be a no-op against
# that empty default and every accelerator would read as unsupported. The
# rule for this file: `?=` for values only this file declares, `=` for values
# the distro pre-declares or the vendor machine conf sets.
EDGE_ACCEL_SUPPORTED = "drpai-v2l"

# --- Network interface roles --------------------------------------------
# eth0 is reserved for the kernel's ip=dhcp NFS-root path on netboot, so
# systemd-networkd must not manage it; eth1 is the DHCP uplink. The same
# image works netbooted or flashed because of this split.
EDGE_UNMANAGED_IFACES = "eth0"
EDGE_UPLINK_IFACE     = "eth1"

# --- Boot chain ---------------------------------------------------------
# TF-A/OP-TEE -> U-Boot -> signed FIT verified against the key in U-Boot's
# control DTB -> raw U-Boot env for RAUC boot-count.
EDGE_BOOT_CHAIN = "uboot-fit"

# --- Kernel provider ----------------------------------------------------
# sbom-cve-check sets the SPDX compiled-sources flag for linux-yocto only.
# Without it this kernel's SPDX omits compiled sources and CVE
# source-attribution over-reports -- silently, in a shipped artefact.
SPDX_INCLUDE_COMPILED_SOURCES:pn-linux-renesas = "1"

# --- RAUC slot block devices --------------------------------------------
# Written into the *signed* dm-verity table, so a wrong value produces a
# correctly-signed image that cannot mount its own root. Partition numbers
# follow the WKS layout: /boot p1, rootfs A p2, rootfs B p3, data p4
# (files/wic/edge-rzv2l.wks.in).
EDGE_BOOT_DEVICE   ?= "/dev/mmcblk0p1"
EDGE_SLOT_A_DEVICE ?= "/dev/mmcblk0p2"
EDGE_SLOT_B_DEVICE ?= "/dev/mmcblk0p3"
EDGE_DATA_DEVICE   ?= "/dev/mmcblk0p4"

# --- Raw U-Boot environment area ----------------------------------------
# Must match CONFIG_ENV_OFFSET / CONFIG_ENV_OFFSET_REDUND / CONFIG_ENV_SIZE
# in the Renesas U-Boot (patch 0002); the bbappend asserts the resolved
# .config carries these values. A mismatch boots fine and silently loses
# RAUC's boot-count.
EDGE_UBOOT_ENV_DEVICE        ?= "/dev/mmcblk0"
EDGE_UBOOT_ENV_OFFSET        ?= "0x1F0000"
EDGE_UBOOT_ENV_OFFSET_REDUND ?= "0x210000"
EDGE_UBOOT_ENV_SIZE          ?= "0x20000"

# --- FIT trust anchor ---------------------------------------------------
# uboot-sign concatenates the signed control DTB into u-boot.bin and deploys
# it under UBOOT_DTB_SYMLINK; the Renesas do_deploy does not touch the DTB.
# This is the file whose /signature node U-Boot verifies slot FITs against.
EDGE_FIT_PUBKEY_DTB ?= "u-boot-${MACHINE}.dtb"

# --- Machine-specific image content -------------------------------------
# mtd-utils: flashcp/flash_erase/nandwrite for the BL2/FIP SPI flash
# partitions exposed by mtd0/mtd1, for in-place FIP updates without pulling
# the SD card.
# packagegroup-edge-optee declares COMPATIBLE_MACHINE on itself, but BitBake
# does NOT fail-soft on a COMPATIBLE_MACHINE-incompatible dependency -- a
# board that listed it would fail parse with "Nothing provides
# packagegroup-edge-optee". Naming it per-board rather than distro-wide is
# what keeps that from happening; the toggle still applies inside.
EDGE_MACHINE_EXTRA_INSTALL ?= "mtd-utils \
    ${@bb.utils.contains('EDGE_ENABLE_OPTEE', '1', 'packagegroup-edge-optee', '', d)}"

# --- Boot artifacts (contract in edge-ab-image.bbclass) ------------------
# Flat deploy basename of the DTB consumed when the image task builds its
# signed slot FITs. splash.bmp is a standalone U-Boot asset.
EDGE_BOOT_DTB         ?= "r9a07g054l2-smarc.dtb"
EDGE_BOOT_EXTRA       ?= "splash.bmp"
EDGE_BOOT_DEPLOY_DEPS ?= "edge-splash-assets:do_deploy trusted-firmware-a:do_deploy edge-kernel-fit:do_deploy"

# --- FIT runtime addresses ----------------------------------------------
# 0x48080000 matches the SoC's kernel text base and U-Boot's bootcmd
# loadaddr. Read by linux-renesas (FIT signing context) and edge-kernel-fit
# (UBOOT_LOADADDRESS / UBOOT_ENTRYPOINT), so it must be conf scope.
EDGE_FIT_LOADADDRESS ?= "0x48080000"
EDGE_FIT_ENTRYPOINT  ?= "0x48080000"

# --- WIC layout ----------------------------------------------------------
# FIP placement for the RZ/V2L eSD boot ROM: sector 256 = 0x20000 bytes,
# the SoC boot-ROM expectation for SD boot (RZ/V2L HW manual, loader
# location / eSD boot mode).
FIP_WIC_OFFSET ?= "--offset 256s"

# WIC expands ${VAR} inside .wks only for variables listed in WICVARS.
# Without this, ${FIP_WIC_OFFSET} passes through literally, argparse eats it
# as a positional mountpoint, --offset goes silently absent, and the FIP
# lands at 0x10000 instead of 0x20000 (RZG2L_SD_FIP_BASE). Boot then dies in
# BL2 before its banner.
WICVARS:append = " FIP_WIC_OFFSET"

# Selected by EDGE_BOOT_TARGET (edge-ab-image.bbclass):
#   esd  -> edge-rzv2l.wks.in       (MBR, BL2 at sector 0, raw env, A/B)
#   emmc -> edge-rzv2l-emmc.wks.in  (GPT user area, BL2 in mmcblk0boot0)
# Both are RZ/V2L SoC-ROM specific.
#
# Plain `=`, not the `:smarc-rzv2l` override form the kas overlay needed:
# this file parses at distro-conf scope (bitbake.conf:828), after
# conf/machine/${MACHINE}.conf (:825), so it already wins over
# smarc-rzv2l.conf:44's conditional without an override.
WKS_FILE = "${@oe.utils.conditional('EDGE_BOOT_TARGET', 'emmc', 'edge-rzv2l-emmc.wks.in', 'edge-rzv2l.wks.in', d)}"
