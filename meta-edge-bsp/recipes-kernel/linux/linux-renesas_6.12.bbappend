FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Human-ratified not-applicable-config CVE decisions (config-unreachable
# only; version/backport gaps are patched, not annotated).
require ${THISDIR}/files/cve-exclusion-renesas-6.12.inc

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

# BTF/CO-RE — independent, OFF by default. btf-core-dev.cfg turns on in-kernel
# BTF (CONFIG_DEBUG_INFO_BTF + _MODULES) over un-reduced DWARF; the build runs
# pahole to emit the .BTF section. Three things are required, all gated together:
#   - btf-core-dev.cfg (the CONFIG_* request)
#   - pahole-native in DEPENDS (meta-oe pahole v1.31; the generator)
#   - KERNEL_DEBUG="True", which makes linux-yocto.inc drop its default
#     `PAHOLE=false` from the config-time make and add pahole-native to
#     do_kernel_configme. Without it, CONFIG_PAHOLE_VERSION probes `false`,
#     resolves to 0, and Kconfig silently drops DEBUG_INFO_BTF even though
#     pahole is in the sysroot.
# Un-reduced DWARF + per-module BTF inflate /lib/modules and the OTA bundle, so
# this is its own gate (separate from JTAG): off for DRP-AI/edge-AI builds, on
# only for libbpf/CO-RE labs.
EDGE_ENABLE_BTF_CORE_DEV ?= "0"
SRC_URI:append = "${@' file://cfg/btf-core-dev.cfg' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"
DEPENDS:append = "${@' pahole-native' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"
KERNEL_DEBUG = "${@'True' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"

# JTAG/OpenOCD source-level kernel-debug fragment — opt-in, off by default.
# Appended last so its KASLR/lockup-detector overrides win the merge over
# crash-debug-dev.cfg. do_kernel_configcheck flags those two symbols as a
# requested-vs-final mismatch; that is the intended override, not an error.
EDGE_ENABLE_JTAG_DEBUG ?= "0"
SRC_URI:append = "${@' file://cfg/jtag-debug.cfg' if d.getVar('EDGE_ENABLE_JTAG_DEBUG') == '1' else ''}"

# Generate the in-tree gdb helpers' constants.py (lx-ps, lx-dmesg, lx-symbols).
# CONFIG_GDB_SCRIPTS=y (jtag-debug.cfg) builds the infra, but constants.py is
# only produced by `make scripts_gdb`; without it `source vmlinux-gdb.py` fails
# with "No module named 'linux'". Emitted into ${B}/scripts/gdb/ for the host
# debugger to source. Gated on the JTAG toggle — no cost on normal builds.
do_compile:append() {
    if [ "${EDGE_ENABLE_JTAG_DEBUG}" = "1" ]; then
        oe_runmake scripts_gdb
    fi
}

# display-rzv2l.cfg: RZ/G2L DU + MIPI-DSI + Lontium LT8912B bridge are =m
# in defconfig; force built-in so the pipeline is up at boot without
# depending on userspace autoload or which kernel-module-* land in rootfs.
#
# 0001 mmc-aliases: without this, async-probe race between sdhi0 and sdhi1
# can put the boot card on mmcblk1 and hang at "Waiting for root device".
# The full downstream chain (signed verity table for /dev/mmcblk0pN,
# slot-udev KERNEL=="mmcblk0pN", /dev/disk/by-rauc-slot/*) assumes
# mmcblk0 = sdhi0 = boot SDHI; the patch makes that hold by construction.
SRC_URI:append:smarc-rzv2l = " \
    file://cfg/display-rzv2l.cfg \
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

# Publish linux.bin + linux_comp into DEPLOY_DIR_IMAGE. Wrynose split FIT
# generation into two stages: this kernel recipe publishes raw artifacts,
# edge-kernel-fit consumes them to assemble and sign the FIT.
KERNEL_CLASSES:append = " kernel-fit-extra-artifacts"

# EDGE_FIT_LOADADDRESS / EDGE_FIT_ENTRYPOINT are set at conf level (from
# kas/machines/<board>.yml's local_conf_header) so both this recipe and
# edge-kernel-fit see them. Defining them here would scope them to this
# recipe only.
