SUMMARY     = "Hexagon NPU inference enablement: QNN HTP v75 runtime + FastRPC"
DESCRIPTION = "On-device Qualcomm QNN stack for the QCS8275 Hexagon NPU: the FastRPC \
userspace, the QAIRT host runtime and tools, the HTP v75 DSP skels and the \
rootless inference Quadlet. Models are layered on top from /data."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "libs"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# The image class installs packagegroup-edge-accel-${EDGE_ACCEL}; this recipe
# carries the derived name directly. Stub (qairt-sdk) and skel
# (qairt-sdk-hexagon-v75) must come from the same QAIRT build.
RDEPENDS:${PN} = " \
    fastrpc \
    qairt-sdk \
    qairt-sdk-hexagon-v75 \
    edge-qnn-htp-quadlet \
"
