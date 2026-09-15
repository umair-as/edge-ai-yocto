FILESEXTRAPATHS:prepend := "${EDGE_BSP_LAYERDIR}/recipes-kernel/linux/files:"

# Human-ratified not-applicable-config CVE decisions (config-unreachable
# only; version/backport gaps are patched, not annotated).
require ${EDGE_BSP_LAYERDIR}/recipes-kernel/linux/files/cve-exclusion-renesas-6.12.inc

# Kernel pin: rz-6.12-cip14 (6.12.59), ~150 version-in-range CVEs clear of the
# cip7 default in the kas-pinned meta-renesas. Newer meta-renesas revisions also
# default to cip14 but name a KERNEL_REV absent from rz_linux-cip; this SRCREV is
# the branch tip and fetches. cip8+ dropped the V2L downstream memory + ISU
# enablement, restored by patches 0009/0010 below, applied before the DRP-AI
# patches anchored to them. Boot + HW validated on 6.12.59.
KERNEL_BRANCH = "rz-6.12-cip14"
KERNEL_REV    = "212f6e88b7249f803ff5475c07b72c92ce2d929d"
LINUX_VERSION = "6.12.59-cip14"

# Kernel customisations on linux-renesas 6.12 (CIP base + Renesas RZ
# enablement, sourced from rz_linux-cip.git at the branch pinned above).
# The machine-neutral fragment set and the resolved-.config assertion are
# provider-neutral policy and live in the include; this file adds only
# what is specific to this provider or this board.
require ${EDGE_BSP_LAYERDIR}/recipes-kernel/linux/edge-kernel-policy.inc

# display-rzv2l.cfg: RZ/G2L DU + MIPI-DSI + Lontium LT8912B bridge are =m
# in defconfig; force built-in so the pipeline is up at boot without
# depending on userspace autoload or which kernel-module-* land in rootfs.
#
# 0001 mmc-aliases: without this, async-probe race between sdhi0 and sdhi1
# can put the boot card on mmcblk1 and hang at "Waiting for root device".
# The full downstream chain (signed verity table for /dev/mmcblk0pN,
# slot-udev KERNEL=="mmcblk0pN", /dev/disk/by-rauc-slot/*) assumes
# mmcblk0 = sdhi0 = boot SDHI; the patch makes that hold by construction.
#
# surface-trim.cfg trims arm64 defconfig support for hardware this SoC
# does not integrate; its every entry reasons from RZ/V2L specifically
# (no PCIe, hence no NVMe; cortex-a55 as the only perf event source;
# RENESAS_USBHS as the only gadget consumer). Board content, not policy.
SRC_URI:append:smarc-rzv2l = " \
    file://cfg/display-rzv2l.cfg \
    file://cfg/surface-trim.cfg \
    file://patches/0001-arm64-dts-rzg2l-smarc-som-add-mmc-aliases.patch \
    file://patches/0001-arm64-dts-rzv2l-smarc-include-ov5645-csi-camera-inline.patch \
    file://patches/0002-arm64-dts-rzg2l-smarc-add-watchdog-channel-id-bindings.patch \
    file://patches/0003-arm64-dts-rzg2l-smarc-som-add-local-mac-address-placeholders.patch \
    file://patches/0009-arm64-dts-rzg2l-smarc-som-restore-v2l-multimedia-reserved-memory.patch \
    file://patches/0010-clk-renesas-r9a07g044-cpg-restore-isu-clocks.patch \
    file://patches/0005-arm64-dts-rzg2l-smarc-som-add-ramoops-reserved-memory.patch \
    file://patches/0006-arm64-dts-rzv2l-smarc-add-drpai-udmabuf-reserved-memory.patch \
    file://patches/0007-arm64-export-dcache-poc-ops-for-drpai-module.patch \
    file://patches/0008-arm64-dts-rzv2l-smarc-add-isu-node.patch \
"
# QSPI FIP alignment — platform boots via eSD; uncomment if QSPI is wired.
# SRC_URI:append:smarc-rzv2l = " file://patches/0004-arm64-dts-rzg2l-smarc-som-align-qspi-fip-partition-to-0x20000.patch"

KERNEL_FEATURES:append = ""

# EDGE_FIT_LOADADDRESS / EDGE_FIT_ENTRYPOINT are set at conf level (from
# kas/machines/<board>.yml's local_conf_header) so both this recipe and
# edge-kernel-fit see them. Defining them here would scope them to this
# recipe only.
