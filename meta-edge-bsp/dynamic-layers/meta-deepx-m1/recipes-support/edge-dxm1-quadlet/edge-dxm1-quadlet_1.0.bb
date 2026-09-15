SUMMARY     = "Rootless Podman quadlet: DX-M1 inference as edge-ctr"
DESCRIPTION = "Systemd Quadlet (.container) that runs a DX-M1 inference \
workload as the rootless edge-ctr principal, passing /dev/dxrt0 into the \
container. The payload (runtime libs + compiled model + runner) is \
bind-mounted from /data/dxm1, off the A/B rootfs."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://dxm1-inference.container"

inherit allarch

S = "${UNPACKDIR}"

# edge-ctr's static uid (files/passwd); podman-user-generator scans
# /etc/containers/systemd/users/<uid>/ for that user's rootless quadlets.
EDGE_CTR_UID = "608"

do_install() {
    install -d ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}
    install -m 0644 ${UNPACKDIR}/dxm1-inference.container \
        ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/dxm1-inference.container
}

RDEPENDS:${PN} = "edge-ctr-user"

FILES:${PN} = "${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/dxm1-inference.container"
