SUMMARY     = "Runtime config for the edge container stack"
DESCRIPTION = "Installs sysctl user-namespace allowance (rootless podman), \
netavark network backend selection in containers.conf, subuid/subgid ranges \
for the devel user, Quadlet drop directories for systemd-managed containers, \
and a tmpfiles.d entry to pre-create the rootless Quadlet path at boot."
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

# Subordinate UID/GID ranges for the devel user — required for rootless
# podman. 65536 IDs from 100000; avoids system (0-999) and devel's UID
# (1000). /etc/sub{u,g}id are owned by the shadow package, so append in
# postinst rather than shipping the files (a shipped copy collides with
# shadow's at do_rootfs). newuidmap/newgidmap come from the base shadow
# package.
pkg_postinst:${PN}() {
    for f in subuid subgid; do
        grep -q '^devel:100000:' $D${sysconfdir}/$f 2>/dev/null || \
            echo 'devel:100000:65536' >> $D${sysconfdir}/$f
    done
}

FILES:${PN} = " \
    ${sysconfdir}/sysctl.d/80-edge-containers.conf \
    ${sysconfdir}/containers/containers.conf.d/10-edge-network.conf \
    ${sysconfdir}/containers/systemd \
    ${nonarch_libdir}/tmpfiles.d/podman-quadlet-devel.conf \
"
