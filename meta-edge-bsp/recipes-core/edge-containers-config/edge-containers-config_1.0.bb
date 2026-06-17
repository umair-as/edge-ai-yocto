SUMMARY     = "Runtime config for the edge container stack"
DESCRIPTION = "Installs sysctl user-namespace allowance (rootless podman), \
CNI network backend selection in containers.conf, subuid/subgid ranges for \
the devel user, Quadlet drop directories for systemd-managed containers, \
and a tmpfiles.d entry to pre-create the rootless Quadlet path at boot."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://50-edge-containers.conf \
    file://10-edge-network.conf \
    file://podman-quadlet-devel.conf \
"

inherit allarch

S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/50-edge-containers.conf \
        ${D}${sysconfdir}/sysctl.d/50-edge-containers.conf

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

    # Subordinate UID/GID ranges for the devel user — required for rootless
    # podman. 65536 IDs starting at 100000; avoids system (0-999) and the
    # devel primary UID (1000). newuidmap/newgidmap (shadow-suid) enforce
    # that only IDs within these ranges can be mapped by devel.
    install -d ${D}${sysconfdir}
    printf 'devel:100000:65536\n' >> ${D}${sysconfdir}/subuid
    printf 'devel:100000:65536\n' >> ${D}${sysconfdir}/subgid
}

FILES:${PN} = " \
    ${sysconfdir}/sysctl.d/50-edge-containers.conf \
    ${sysconfdir}/containers/containers.conf.d/10-edge-network.conf \
    ${sysconfdir}/containers/systemd \
    ${nonarch_libdir}/tmpfiles.d/podman-quadlet-devel.conf \
    ${sysconfdir}/subuid \
    ${sysconfdir}/subgid \
"
