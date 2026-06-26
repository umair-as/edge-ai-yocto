FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Kernel customisations on linux-renesas 6.12 (CIP base + Renesas RZ
# enablement, sourced from rz_linux-cip.git rz-6.12-cip7 by meta-renesas).
# Wires kconfig fragments for crypto/RNG, RAUC verity, containers, AI compute.

SRC_URI:append = " \
    file://cfg/rauc-verity.cfg \
    file://cfg/hwcrypto-hwrng.cfg \
    file://cfg/dm-crypt.cfg \
    file://cfg/containers-cgroups.cfg \
    file://cfg/container-storage-net.cfg \
    file://cfg/ai-compute.cfg \
    file://cfg/security-hardening.cfg \
    file://cfg/pstore-persist.cfg \
"

# Dev-only fragments — gated so we don't bake debug/tracing surface into
# prod images. EDGE_KERNEL_DEV_FRAGMENTS defaults on; flip to "0" in the
# prod image variant (Phase 2) to drop observability bits.
EDGE_KERNEL_DEV_FRAGMENTS ?= "1"
SRC_URI:append = "${@' file://cfg/observability-dev.cfg file://cfg/crash-debug-dev.cfg' if d.getVar('EDGE_KERNEL_DEV_FRAGMENTS') == '1' else ''}"

# display-rzv2l.cfg: RZ/G2L DU + MIPI-DSI + Lontium LT8912B bridge are =m
# in defconfig; force built-in so the pipeline is up at boot without
# depending on userspace autoload or which kernel-module-* land in rootfs.
#
# 0001 mmc-aliases: without this, async-probe race between sdhi0 and sdhi1
# can put the boot card on mmcblk1 and hang at "Waiting for root device".
# The full downstream chain (rauc_set_bootargs root=/dev/mmcblk0pN,
# slot-udev KERNEL=="mmcblk0pN", /dev/disk/by-rauc-slot/*) assumes
# mmcblk0 = sdhi0 = boot SDHI; the patch makes that hold by construction.
SRC_URI:append:smarc-rzv2l = " \
    file://cfg/display-rzv2l.cfg \
    file://patches/0001-arm64-dts-rzg2l-smarc-som-add-mmc-aliases.patch \
    file://patches/0001-arm64-dts-rzv2l-smarc-include-ov5645-csi-camera-inline.patch \
    file://patches/0002-arm64-dts-rzg2l-smarc-add-watchdog-channel-id-bindings.patch \
    file://patches/0003-arm64-dts-rzg2l-smarc-som-add-local-mac-address-placeholders.patch \
    file://patches/0005-arm64-dts-rzg2l-smarc-som-add-ramoops-reserved-memory.patch \
    file://patches/0006-arm64-dts-rzv2l-smarc-add-drpai-udmabuf-reserved-memory.patch \
    file://patches/0007-arm64-export-dcache-poc-ops-for-drpai-module.patch \
    file://patches/0008-arm64-dts-rzv2l-smarc-add-isu-node.patch \
"
# QSPI FIP alignment — platform boots via eSD; uncomment if QSPI is wired.
# SRC_URI:append:smarc-rzv2l = " file://patches/0004-arm64-dts-rzg2l-smarc-som-align-qspi-fip-partition-to-0x20000.patch"

KERNEL_FEATURES:append = ""

# Publish linux.bin + linux_comp into DEPLOY_DIR_IMAGE. Wrynose split FIT
# generation into two stages: this kernel recipe publishes raw artifacts,
# edge-kernel-fit consumes them to assemble and sign the FIT.
KERNEL_CLASSES:append = " kernel-fit-extra-artifacts"

# EDGE_FIT_LOADADDRESS / EDGE_FIT_ENTRYPOINT are set at conf level (from
# kas/machines/<board>.yml's local_conf_header) so both this recipe and
# edge-kernel-fit see them. Defining them here would scope them to this
# recipe only.
