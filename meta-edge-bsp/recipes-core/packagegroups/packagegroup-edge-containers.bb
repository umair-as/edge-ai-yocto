SUMMARY     = "podman + skopeo + overlay graph drivers + CNI plugins + rootless support"
DESCRIPTION = "OCI container userspace: podman engine, skopeo image tooling, \
native overlay and fuse-overlayfs graph drivers, CNI networking plugins, \
slirp4netns for rootless container networking, and edge runtime config."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

RDEPENDS:${PN} = " \
    podman \
    skopeo \
    fuse-overlayfs \
    cni \
    slirp4netns \
    shadow-suid \
    edge-containers-config \
"
