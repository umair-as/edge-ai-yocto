SUMMARY     = "Rootless Podman quadlet: QNN HTP inference as edge-ctr"
DESCRIPTION = "Systemd Quadlet that runs a QNN context binary on the Hexagon NPU as the \
rootless edge-ctr principal with the FastRPC compute-DSP node passed in; the model \
and inputs are bind-mounted from /data/qnn-htp, off the A/B rootfs."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://qnn-htp-inference.container"

inherit allarch

S = "${UNPACKDIR}"

# edge-ctr's static uid (files/passwd); podman-user-generator scans
# /etc/containers/systemd/users/<uid>/ for that user's rootless quadlets.
EDGE_CTR_UID = "608"

do_install() {
    install -d ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}
    install -m 0644 ${UNPACKDIR}/qnn-htp-inference.container \
        ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/qnn-htp-inference.container
}

RDEPENDS:${PN} = "edge-ctr-user"

FILES:${PN} = "${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/qnn-htp-inference.container"
