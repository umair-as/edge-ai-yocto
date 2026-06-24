SUMMARY     = "DRP-AI inference enablement: kernel drivers + TVM runtime"
DESCRIPTION = "On-device DRP-AI stack for RZ/V2L: the drpai kernel driver \
(/dev/drpai0), the u-dma-buf and mmngr buffer providers, and the prebuilt \
DRP-AI TVM (RUHMI) runtime that executes compiled models. Models are layered \
on top separately."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "kernel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# RDEPENDS pull machine-arch kernel modules — set PACKAGE_ARCH before the
# packagegroup inherit so the group ships as MACHINE_ARCH, not allarch.
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# DRP-AI is RZ/V2L-only SoC IP.
COMPATIBLE_MACHINE = "smarc-rzv2l"

# mmngr/mmngrbuf nodes + linux,multimedia carveout are already in the base
# rzg2l-smarc-som.dtsi; these modules bind them. drpai-tvm-runtime links the
# mmngr userspace libs for DRP-AI work buffers.
#
# drpai-tvm-app: native inference binary. edge-ctr-user + drpai-tvm-quadlet:
# dedicated rootless container principal and its inference Quadlet — the
# containerized path runs as edge-ctr, not the interactive devel login.
RDEPENDS:${PN} = " \
    kernel-module-drpai \
    kernel-module-u-dma-buf \
    kernel-module-mmngr \
    kernel-module-mmngrbuf \
    mmngr-user-module \
    mmngrbuf-user-module \
    drpai-tvm-runtime \
    drpai-tvm-app \
    edge-drpai-udev \
    edge-ctr-user \
    drpai-tvm-quadlet \
"
