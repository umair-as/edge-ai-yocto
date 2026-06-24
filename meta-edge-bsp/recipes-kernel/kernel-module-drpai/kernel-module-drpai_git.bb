SUMMARY     = "RZ/V2L DRP-AI accelerator kernel driver (out-of-tree module)"
DESCRIPTION = "Loadable kernel module for the DRP-AI inference accelerator on \
RZ/V2L. Creates /dev/drpai0, binds the renesas,rzv2l-drpai device-tree node, \
and serves userspace runtimes via ioctl over dma-buf/CMA buffers."
HOMEPAGE    = "https://github.com/umair-as/rzv2l-drpai-driver"
SECTION     = "kernel"
LICENSE     = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit module

# Renesas GPL-2.0 driver, repackaged out-of-tree and forward-ported to
# linux-cip 6.12. DRP-AI is RZ/V2L-only SoC IP; the drpai DT node +
# drp_reserved carveout are wired in the linux-renesas bbappend DTS.
SRC_URI = "git://github.com/umair-as/rzv2l-drpai-driver.git;protocol=https;branch=main"
SRCREV  = "bfb9f19a265f87c5c29721a3fbde6e61f8d68002"

PV = "1.0+git${SRCPV}"

COMPATIBLE_MACHINE = "smarc-rzv2l"

KERNEL_MODULE_AUTOLOAD += "drpai"

# UAPI header carries the ioctl definitions userspace runtimes compile against;
# ships to the SDK sysroot (-dev), not the runtime rootfs.
do_install:append() {
    install -d ${D}${includedir}/linux
    install -m 0644 ${S}/include/uapi/linux/drpai.h ${D}${includedir}/linux/
}

FILES:${PN}-dev += "${includedir}/linux/drpai.h"
