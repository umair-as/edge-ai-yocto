SUMMARY     = "Dev image: edge-image-base + profiling, debug, stress tools"
DESCRIPTION = "Layers gdb, strace, perf, systemd-analyze, stress-ng, htop, \
iotop, tcpdump, and shell QoL on top of edge-image-base. For bring-up, \
perf investigation, and reproducer harnesses."
HOMEPAGE   = "https://github.com/umair-as/edge-ai-yocto"
SECTION    = "base"
LICENSE    = "MIT"

require recipes-core/images/edge-image-common.inc

# Dev tier. Pulls edge-profile-dev.inc via the distro's require chain
# (OVERRIDES picks up :dev, observability defaults on).
EDGE_PROFILE = "dev"

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
# `dnf install` at runtime (package-management is on via edge-image-common.inc).
IMAGE_INSTALL:append = " packagegroup-edge-dev edge-sudoers-nopasswd"
# edge-sudoers-nopasswd is the bench-tier sub-package of edge-sudoers; it
# ships 15-edge-wheel-nopasswd which lexically overrides 10-edge-wheel
# and makes %wheel passwordless. edge-image-base intentionally omits it
# so prod keeps the interactive password gate.

# Machine-gated dev-only OP-TEE conformance suite. Cannot live in
# packagegroup-edge-dev — that recipe is machine-portable; the test slice
# is on packagegroup-edge-optee which is COMPATIBLE_MACHINE=smarc-rzv2l.
# packagegroup-edge-optee-test is the ${PN}-test output package of the
# packagegroup-edge-optee recipe.
IMAGE_INSTALL:append:smarc-rzv2l = " packagegroup-edge-optee-test"

# Optional: dbg-pkgs ships -dbg sub-packages for every recipe so gdb
# backtraces resolve symbols. Roughly 3x rootfs size; gate behind a
# variable for per-build opt-in.
EDGE_DEV_DBG_PKGS ?= "0"
IMAGE_FEATURES:append = "${@' dbg-pkgs' if d.getVar('EDGE_DEV_DBG_PKGS') == '1' else ''}"
