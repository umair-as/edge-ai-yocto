SUMMARY     = "Edge dev tier roll-up: shell + diagnostics packagegroups"
DESCRIPTION = "Aggregates the dev-image packagegroups: shell QoL, \
observability, hwtools, netdiag, storage, media. Machine-gated extras are \
added at the image level so this recipe stays portable across machines."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
# Observability is gated by EDGE_ENABLE_OBSERVABILITY at the image level
# (edge-image.bbclass), not pinned here. Profile :dev defaults the
# toggle on, so a default dev build still ships it.
RDEPENDS:${PN} = " \
    packagegroup-edge-shell \
    packagegroup-edge-hwtools \
    packagegroup-edge-netdiag \
    packagegroup-edge-storage \
    packagegroup-edge-media \
"
