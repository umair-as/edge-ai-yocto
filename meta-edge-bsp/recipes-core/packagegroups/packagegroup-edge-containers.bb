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

# nftables: netavark is configured with firewall_driver = "nftables"
# (edge-containers-config) and execs the nft binary for every root
# container network; without it `podman run` as root fails with "unable
# to execute nft". Rootless containers (pasta) never touch it, which is
# why the rootless proofs passed without this.
RDEPENDS:${PN} = " \
    podman \
    conmon \
    crun \
    netavark \
    aardvark-dns \
    nftables \
    passt \
    slirp4netns \
    catatonit \
    skopeo \
    shadow-uidmap \
    edge-containers-config \
    edge-ctr-user \
"
