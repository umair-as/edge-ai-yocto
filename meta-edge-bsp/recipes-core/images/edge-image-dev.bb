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
            "requires EDGE_PROFILE=dev (got '%s'); build with 'make dev' "
            "or set EDGE_PROFILE=dev" % p)
}

# Pull in the standard oe-core debug + profile feature buckets. They drag
# in gdb/gdbserver/strace/ltrace/tcpdump (tools-debug) and perf/lttng-tools
# (tools-profile). Cheaper than naming each package directly and tracks
# upstream changes.
IMAGE_FEATURES:append = " \
    tools-debug \
    tools-profile \
"

# Dev tier — single packagegroup handle aggregating shell QoL,
# observability, hwtools, netdiag, storage, and media. New dev userspace
# is added by editing a packagegroup recipe in
# meta-edge-bsp/recipes-core/packagegroups/, not this file. Ad-hoc tools:
# Package metadata remains available for inspection; the authenticated local
# root is read-only. NFS netboot is the writable development workflow.
IMAGE_INSTALL:append = " packagegroup-edge-dev edge-sudoers-nopasswd edge-debug-mode"
# edge-sudoers-nopasswd is the bench-tier sub-package of edge-sudoers; it
# ships 15-edge-wheel-nopasswd which lexically overrides 10-edge-wheel
# and makes %wheel passwordless. edge-image-base intentionally omits it
# so prod keeps the interactive password gate.

# Machine-gated dev-only OP-TEE conformance suite. Cannot live in
# packagegroup-edge-dev — that recipe is machine-portable; the test slice
# is on packagegroup-edge-optee which is COMPATIBLE_MACHINE=smarc-rzv2l.
# packagegroup-edge-optee-test is the ${PN}-test output package of the
# packagegroup-edge-optee recipe. Follows EDGE_ENABLE_OPTEE: xtest against a
# TEE that the image has no client stack for is dead weight.
IMAGE_INSTALL:append:smarc-rzv2l = "${@bb.utils.contains('EDGE_ENABLE_OPTEE', '1', ' packagegroup-edge-optee-test', '', d)}"

# packagegroup-edge-ai-test is the ${PN}-test output package of the
# packagegroup-edge-ai recipe: drpai-classify and drpai-runner. Follows
# EDGE_ENABLE_AI for the same reason as the OP-TEE slice above — measurement
# instruments belong in a dev image, not in prod.
IMAGE_INSTALL:append:smarc-rzv2l = "${@bb.utils.contains('EDGE_ENABLE_AI', '1', ' packagegroup-edge-ai-test', '', d)}"

# Optional: dbg-pkgs ships -dbg sub-packages for every recipe so gdb
# backtraces resolve symbols. Roughly 3x rootfs size; gate behind a
# variable for per-build opt-in.
EDGE_DEV_DBG_PKGS ?= "0"
IMAGE_FEATURES:append = "${@' dbg-pkgs' if d.getVar('EDGE_DEV_DBG_PKGS') == '1' else ''}"

# JTAG/OpenOCD source-level kernel debugging. Off by default. When "1":
# linux-renesas adds jtag-debug.cfg (KASLR off, un-reduced DWARF, -Og, lockup
# detectors out, kgdb in), and edge-debug-mode pre-places the watchdog-off
# + sysctl-relax drop-ins so the image boots debug-safe. Pairs with
# EDGE_DEV_DBG_PKGS=1 for on-target -dbg symbols. Cheap on OTA size: the
# debug DWARF lives in the build-tree vmlinux and is stripped from the image.
EDGE_ENABLE_JTAG_DEBUG ?= "0"

# BPF/CO-RE labs. Off by default — this is the size-heavy toggle (kernel BTF
# over un-reduced DWARF + per-module BTF in /lib/modules grow the OTA bundle).
# When "1": linux-renesas adds btf-core-dev.cfg (/sys/kernel/btf/vmlinux) and
# the image pulls packagegroup-edge-bpf (bpftool, ...). Leave off for
# DRP-AI/edge-AI builds.
EDGE_ENABLE_BTF_CORE_DEV ?= "0"
IMAGE_INSTALL:append = "${@' packagegroup-edge-bpf' if d.getVar('EDGE_ENABLE_BTF_CORE_DEV') == '1' else ''}"
