SUMMARY     = "Runtime config for the edge container stack"
DESCRIPTION = "Installs sysctl user-namespace allowance (rootless podman), \
network backend and image-copy scratch-dir settings in containers.conf, \
Quadlet drop directories for systemd-managed containers, and a tmpfiles.d \
entry to pre-create the rootless Quadlet path at boot."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://80-edge-containers.conf \
    file://10-edge-network.conf \
    file://podman-quadlet-devel.conf \
"

inherit allarch

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/80-edge-containers.conf \
        ${D}${sysconfdir}/sysctl.d/80-edge-containers.conf

    install -d ${D}${sysconfdir}/containers/containers.conf.d
    install -m 0644 ${UNPACKDIR}/10-edge-network.conf \
        ${D}${sysconfdir}/containers/containers.conf.d/10-edge-network.conf

    # Quadlet drop directory for rootful (system) containers.
    # podman-system-generator scans this at boot and converts .container /
    # .volume / .network files into systemd service units transparently.
    install -d ${D}${sysconfdir}/containers/systemd

    # tmpfiles.d entry pre-creates ~/.config/containers/systemd/ for devel
    # so the rootless Quadlet path exists before the first user session.
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/podman-quadlet-devel.conf \
        ${D}${nonarch_libdir}/tmpfiles.d/podman-quadlet-devel.conf

}

# Subordinate uid/gid ranges (devel, edge-ctr) are written by
# edge_write_subid_ranges in edge-users.inc. They cannot be provisioned from a
# recipe postinst: /etc/sub{u,g}id belong to the shadow package, which a
# read-only-rootfs image erases (ROOTFS_RO_UNNEEDED) after all postinsts run,
# taking any appended ranges with it. Only ROOTFS_POSTUNINSTALL_COMMAND runs
# after that erase.

FILES:${PN} = " \
    ${sysconfdir}/sysctl.d/80-edge-containers.conf \
    ${sysconfdir}/containers/containers.conf.d/10-edge-network.conf \
    ${sysconfdir}/containers/systemd \
    ${nonarch_libdir}/tmpfiles.d/podman-quadlet-devel.conf \
"
