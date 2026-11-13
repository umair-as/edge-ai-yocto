# EDGE OS rootfs post-process: write /etc/buildinfo.
#
# Inherited by every edge image via edge-image.bbclass (which inherits
# this class). Single ROOTFS_POSTPROCESS_COMMAND hook —
# writes a KEY=VALUE manifest of the image build identity to
# /etc/buildinfo so operators (and RAUC, and provenance tooling) can
# answer "which image is this exactly" without parsing /etc/os-release
# or guessing from package versions.
#
# The file is identical across both A and B slots after install
# because both slots flash the same FS image. It's also identical
# across reboots — written once at do_rootfs time, never refreshed.
#
# What's deliberately NOT here:
#   - host identity (BUILD_SYS) — leaks build-host info to the device.
#     Gated by EDGE_BUILDINFO_INCLUDE_BUILD_SYS.
#   - signing key fingerprints — provenance, not build identity.

# Toggle: include the BUILD_SYS line. Off by default; "1" adds it.
EDGE_BUILDINFO_INCLUDE_BUILD_SYS ?= "0"

edge_rootfs_buildinfo() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}
    {
        echo "DISTRO=${DISTRO}"
        echo "DISTRO_NAME=${DISTRO_NAME}"
        echo "DISTRO_VERSION=${DISTRO_VERSION}"
        echo "EDGE_BUILD_ID=${EDGE_BUILD_ID}"
        echo "EDGE_BUILD_DATE=${EDGE_BUILD_DATE}"
        echo "MACHINE=${MACHINE}"
        echo "TUNE_PKGARCH=${TUNE_PKGARCH}"
        echo "IMAGE_BASENAME=${IMAGE_BASENAME}"
        echo "IMAGE_NAME=${IMAGE_NAME}"
        # Accelerator composition, read by edge-smoke-test.sh.
        echo "EDGE_ACCEL=${@d.getVar('EDGE_ACCEL') or 'none'}"
        echo "EDGE_ALLOW_NO_ACCEL=${@d.getVar('EDGE_ALLOW_NO_ACCEL') or '0'}"
        # EDGE_DEV_NETBOOT is set by kas/dev-netboot.yml — surfaces dev
        # vs prod compose in a single field operators can grep.
        echo "EDGE_DEV_NETBOOT=${EDGE_DEV_NETBOOT}"
        if [ "${EDGE_BUILDINFO_INCLUDE_BUILD_SYS}" = "1" ]; then
            echo "BUILD_SYS=${BUILD_SYS}"
        fi
    } > ${IMAGE_ROOTFS}${sysconfdir}/buildinfo
    chmod 0644 ${IMAGE_ROOTFS}${sysconfdir}/buildinfo
}

ROOTFS_POSTPROCESS_COMMAND += " edge_rootfs_buildinfo;"
