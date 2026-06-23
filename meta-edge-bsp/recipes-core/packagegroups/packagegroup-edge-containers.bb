SUMMARY     = "podman + skopeo + native overlay + netavark networking + rootless"
DESCRIPTION = "OCI container userspace: podman engine, skopeo image tooling, \
native overlay graph driver, netavark + aardvark-dns networking, pasta + \
slirp4netns for rootless container networking, and edge runtime config."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

RDEPENDS:${PN} = " \
    podman \
    conmon \
    crun \
    netavark \
    aardvark-dns \
    passt \
    slirp4netns \
    catatonit \
    skopeo \
    edge-containers-config \
"
