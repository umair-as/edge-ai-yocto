SUMMARY     = "Bundled DX-M1 app image and its rootless Quadlet, no registry"
DESCRIPTION = "Installs edge-dxm1-app-container as an OCI archive on the read-only \
rootfs and a rootless Quadlet that runs it as edge-ctr with Pull=never. The \
model stays on /data/dxm1/model."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
# The archive carries dx-rt, which is Proprietary; the Quadlet is MIT.
LICENSE     = "MIT & Proprietary"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://dxm1-app.container"

S = "${UNPACKDIR}"

# The archive holds machine-specific binaries from DEPLOY_DIR_IMAGE.
PACKAGE_ARCH = "${MACHINE_ARCH}"

EDGE_DXM1_APP_IMAGE = "edge-dxm1-app-container"
# edge-ctr's static uid (files/passwd); podman-user-generator scans
# /etc/containers/systemd/users/<uid>/ for that user's rootless quadlets.
EDGE_CTR_UID = "608"

do_install[depends] += "${EDGE_DXM1_APP_IMAGE}:do_image_complete"

do_install() {
    layout=${DEPLOY_DIR_IMAGE}/${EDGE_DXM1_APP_IMAGE}-latest-oci
    [ -f "$layout/index.json" ] || bbfatal "no OCI layout at $layout"

    # An oci-archive is a tar of the layout root. Fixed order, owner and mtime
    # make the archive a function of the layout alone.
    install -d ${D}${datadir}/edge-oci
    tar --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime=@${SOURCE_DATE_EPOCH} \
        -C "$layout/" -cf ${D}${datadir}/edge-oci/dxm1-app.tar .
    chmod 0644 ${D}${datadir}/edge-oci/dxm1-app.tar

    install -d ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}
    install -m 0644 ${UNPACKDIR}/dxm1-app.container \
        ${D}${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/dxm1-app.container

    # Both Quadlets are wanted by default.target; with both payloads staged
    # the boot transaction holds two conflicting start jobs and systemd drops
    # an arbitrary one. Installing this package selects it: the legacy unit is
    # masked (/etc/systemd/user outranks the Quadlet generator's output).
    install -d ${D}${sysconfdir}/systemd/user
    ln -sf /dev/null ${D}${sysconfdir}/systemd/user/dxm1-inference.service
}

RDEPENDS:${PN} = "edge-ctr-user edge-dxm1-runtime"

FILES:${PN} = " \
    ${datadir}/edge-oci/dxm1-app.tar \
    ${sysconfdir}/containers/systemd/users/${EDGE_CTR_UID}/dxm1-app.container \
    ${sysconfdir}/systemd/user/dxm1-inference.service \
"
