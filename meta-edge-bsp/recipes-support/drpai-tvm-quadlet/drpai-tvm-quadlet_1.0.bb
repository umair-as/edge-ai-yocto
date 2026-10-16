SUMMARY     = "Rootless Podman quadlet: DRP-AI inference as edge-ctr"
DESCRIPTION = "Systemd Quadlet that runs the DRP-AI ResNet18 workload as the rootless \
edge-ctr principal with /dev/drpai0 and /dev/udmabuf0 passed in; the payload \
(app, runtime, model) is bind-mounted from /data/drpai."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://drpai-inference.container"

inherit allarch

S = "${UNPACKDIR}"

# edge-ctr's static uid (files/passwd). podman-user-generator scans
# /etc/containers/systemd/users/<uid>/ for that user's rootless quadlets.
EDGE_CTR_UID = "608"

do_install() {
    install -d ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}
    install -m 0644 ${UNPACKDIR}/drpai-inference.container \
        ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/drpai-inference.container
}

RDEPENDS:${PN} = "edge-ctr-user"

FILES:${PN} = "${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/drpai-inference.container"
