SUMMARY     = "Dev image: edge-image-base + profiling, debug, stress tools"
DESCRIPTION = "Layers gdb, strace, perf, systemd-analyze, stress-ng, htop, \
iotop, tcpdump, and shell QoL on top of edge-image-base. For bring-up, \
perf investigation, and reproducer harnesses."
HOMEPAGE   = "https://github.com/umair-as/edge-ai-yocto"
SECTION    = "base"
LICENSE    = "MIT"

inherit edge-ab-image

WKS_SEARCH_PATH = "${THISDIR}/files/wic"

# Dev tier. EDGE_PROFILE is resolved at distro-parse from the environment
# (make dev exports it); setting it here would be too late to steer the
# distro's `require edge-profile-${EDGE_PROFILE}.inc`. Read it and self-skip
# on a tier/image mismatch. SkipRecipe, not bb.fatal: the anonymous python
# runs for every parsed recipe, so a hard fatal here would abort unrelated
# builds (e.g. edge-image-prod aborting a dev build). Skipping just makes
# this image unbuildable under the wrong tier, with the reason shown.
python () {
    p = d.getVar('EDGE_PROFILE')
    if p != 'dev':
        raise bb.parse.SkipRecipe(
            "requires EDGE_PROFILE=dev (got '%s'); build with 'make dev'" % p)
}

# Pull in the standard oe-core debug + profile feature buckets: gdb,
# gdbserver, strace (tools-debug) and perf, lttng-tools (tools-profile).
# Tracks upstream changes to those sets.
IMAGE_FEATURES:append = " \
    tools-debug \
    tools-profile \
"

# Dev tier — single packagegroup handle aggregating shell QoL,
# observability, hwtools, netdiag, storage, and media. New dev userspace
# goes into a packagegroup recipe in recipes-core/packagegroups/, not this
# file. The verity root is read-only; NFS netboot is the writable
# development workflow.
IMAGE_INSTALL:append = " packagegroup-edge-dev edge-sudoers-nopasswd edge-debug-mode"
# edge-sudoers-nopasswd is the bench-tier sub-package of edge-sudoers; it
# ships 15-edge-wheel-nopasswd which lexically overrides 10-edge-wheel
# and makes %wheel passwordless. edge-image-base and edge-image-prod omit
# it and keep the interactive password gate.

# Board-supplied dev-only packages, named by the board include.
IMAGE_INSTALL:append = "${@' ' + d.getVar('EDGE_MACHINE_DEV_INSTALL') if d.getVar('EDGE_MACHINE_DEV_INSTALL') else ''}"

# Accelerator test/measurement instruments, named by the accelerator
# fragment so this recipe carries no board override.
IMAGE_INSTALL:append = " ${EDGE_ACCEL_TEST_INSTALL}"

# Optional: dbg-pkgs ships -dbg sub-packages for every recipe so gdb
# backtraces resolve symbols. Roughly 3x rootfs size; gate behind a
# variable for per-build opt-in.
EDGE_DEV_DBG_PKGS ?= "0"
IMAGE_FEATURES:append = "${@' dbg-pkgs' if d.getVar('EDGE_DEV_DBG_PKGS') == '1' else ''}"

# JTAG/OpenOCD source-level kernel debugging. Off by default. When "1":
# the kernel (edge-kernel-policy.inc) adds jtag-debug.cfg (KASLR off,
# un-reduced DWARF, lockup detectors out, kgdb in), and edge-debug-mode pre-places the watchdog-off
# + sysctl-relax drop-ins so the image boots debug-safe. Pairs with
# EDGE_DEV_DBG_PKGS=1 for on-target -dbg symbols. Cheap on OTA size: the
# debug DWARF lives in the build-tree vmlinux and is stripped from the image.
EDGE_ENABLE_JTAG_DEBUG ?= "0"

# BPF/CO-RE labs. Off by default — this is the size-heavy toggle (kernel BTF
# over un-reduced DWARF + per-module BTF in /lib/modules grow the OTA bundle).
# When "1": the kernel (edge-kernel-policy.inc) adds btf-core-dev.cfg
# (/sys/kernel/btf/vmlinux) and the image pulls packagegroup-edge-bpf
# (bpftool, ...).
EDGE_ENABLE_BTF_CORE_DEV ?= "0"
IMAGE_INSTALL:append = "${@' packagegroup-edge-bpf' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"

# Bootchain updaters, named by the board (EDGE_MACHINE_BOOTLOADER_UPDATE_INSTALL).
# Off by default: single-copy bootchain storage. BOOTLOADER_UPDATE=1.
EDGE_ENABLE_BOOTLOADER_UPDATE ?= "0"
IMAGE_INSTALL:append = "${@bb.utils.contains('EDGE_ENABLE_BOOTLOADER_UPDATE', '1', ' ' + (d.getVar('EDGE_MACHINE_BOOTLOADER_UPDATE_INSTALL') or ''), '', d)}"
