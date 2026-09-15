# The recipe is named 2.6.0 but its SRCREV is the v2.4.1 commit (module
# reports 2.2.0). Repinned to the real v2.6.0 tip, which carries what this
# board needs: PCIe link-health monitoring with an MMIO guard (the old tree
# took a fatal SError on the runtime's first MMIO after a probe with Mem-
# and BusMaster- clear), and the RPI_BUILD code path below.
SRCREV = "7074748e7104f470b02f517583abba652b3f05fa"

# wrynose source layout: the recipe's S = "${WORKDIR}/git/modules" is a hard
# QA error since oe-core dropped the source-move shim; the checkout lands at
# ${UNPACKDIR}/${BP}. LIC_FILES_CHKSUM is S-relative and follows.
S = "${UNPACKDIR}/${BP}/modules"

# Module signing: the recipe's install target routes through Kbuild's
# modules_install, and the kernel policy sets CONFIG_MODULE_SIG_ALL, so Kbuild
# signs the .ko. edge-image.bbclass then checks every module in the image
# carries a trailer. No second signer here.

# BCM2712 MSI path. v2.6.0 forces a single MSI vector behind RPI_BUILD
# (the brcmstb MSI controller hands out unaligned base data and NPU-done
# interrupts are otherwise dropped), but upstream gates it on the substring
# "rpi" in KERNEL_DIR, which a Yocto STAGING_KERNEL_BUILDDIR path
# ("raspberrypi5") never contains. Passed explicitly; it is upstream's own
# make flag, not a Kconfig symbol, despite the prefix.
EXTRA_OEMAKE:append:raspberrypi5 = " CONFIG_RPI_BUILD=1"

# Prove the flag reached the object rather than trusting the make line: the
# single-MSI path logs a fixed string that is absent when it compiled out.
do_install[postfuncs] += "${@'edge_check_dx_rpi_build' if bb.utils.contains('MACHINEOVERRIDES', 'raspberrypi5', True, False, d) else ''}"
edge_check_dx_rpi_build() {
    ko=$(find ${D}${nonarch_base_libdir}/modules -name 'dx_dma.ko' | head -1)
    [ -n "$ko" ] || bbfatal "dx_dma.ko not installed"
    if ! grep -qa 'forcing single MSI' "$ko"; then
        bbfatal "dx_dma.ko has no single-MSI path: CONFIG_RPI_BUILD did not reach Kbuild"
    fi
}

# No KERNEL_MODULE_AUTOLOAD. A modules-load.d entry loads dx_dma before the
# PCIe bus exists; dxrt_driver enumerates devices once at init and never
# rescans, so /dev/dxrt* is never created. udev autoloads dx_dma from its PCI
# modalias when the endpoint enumerates, and the shipped softdep pulls
# dxrt_driver in behind it. The PCIe bridge is built in on this board
# (pcie-rpi5.cfg) as well.

# kernel-module-split names out-of-tree module packages
# kernel-module-<name>-${KERNEL_VERSION} with no versionless RPROVIDES, so an
# image cannot name them stably; this package depends on its own modules.
RDEPENDS:${PN} += " \
    kernel-module-dx-dma-${KERNEL_VERSION} \
    kernel-module-dxrt-driver-${KERNEL_VERSION} \
"

# Device policy is edge-dxm1-runtime's (root:dxrt 0660). Upstream's own
# do_install writes a MODE="0666" rule; two packages owning one path is an
# RPM conflict at do_rootfs, so it is removed here, not overridden.
do_install:append() {
    rm -f ${D}${sysconfdir}/udev/rules.d/99-dx-dma.rules
    rmdir --ignore-fail-on-non-empty ${D}${sysconfdir}/udev/rules.d ${D}${sysconfdir}/udev 2>/dev/null || true
}
FILES:${PN}:remove = "${sysconfdir}/udev/rules.d/99-dx-dma.rules"
