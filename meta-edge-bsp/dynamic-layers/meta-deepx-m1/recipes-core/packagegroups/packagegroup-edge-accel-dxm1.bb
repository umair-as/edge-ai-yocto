SUMMARY     = "DX-M1 inference enablement: kernel modules + DXRT runtime"
DESCRIPTION = "On-device DEEPX DX-M1 stack: the dx_dma PCIe and dxrt_driver \
chardev modules, the DXRT runtime and daemon, the project's device policy and \
service identity, and the rootless inference Quadlet. Models are layered on top."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "kernel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# RDEPENDS pull machine-arch kernel modules -- set before the inherit.
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# The image class installs packagegroup-edge-accel-${EDGE_ACCEL}; this recipe
# carries the derived name directly.
#
# dx-driver rather than the kernel-module-* packages: kernel-module-split
# names out-of-tree modules kernel-module-<name>-${KERNEL_VERSION} with no
# versionless RPROVIDES, so they cannot be named stably here. The dx-driver
# bbappend makes that package depend on its own modules instead.
RDEPENDS:${PN} = " \
    dx-driver \
    dx-rt \
    edge-dxm1-runtime \
    edge-dxm1-quadlet \
"
