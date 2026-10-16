SUMMARY     = "RZ/V2L DRP-AI accelerator kernel driver (out-of-tree module)"
DESCRIPTION = "DRP-AI accelerator module for RZ/V2L: binds renesas,rzv2l-drpai, \
creates /dev/drpai0 and serves runtimes via read/write/ioctl over buffers in \
the drp_reserved memblock carveout (not a CMA pool)."
HOMEPAGE    = "https://github.com/umair-as/rzv2l-drpai-driver"
SECTION     = "kernel"
LICENSE     = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit module

# Renesas GPL-2.0 driver 2.30 (RZ/V2L AI SDK v8.00), repackaged out-of-tree,
# forward-ported to linux-cip 6.12 and hardened (see the repo README).
# DRP-AI is RZ/V2L-only SoC IP; the drpai DT node + drp_reserved carveout are
# wired in the linux-renesas bbappend DTS.
SRC_URI = "git://github.com/umair-as/rzv2l-drpai-driver.git;protocol=https;branch=main"
SRCREV  = "5827b56eaef32a6fe3359323e6db4e1f963cb885"

PV = "2.30+git"

COMPATIBLE_MACHINE = "smarc-rzv2l"

KERNEL_MODULE_AUTOLOAD += "drpai"

# UAPI header carries the ioctl definitions userspace runtimes compile against;
# ships to the SDK sysroot (-dev), not the runtime rootfs.
do_install:append() {
    install -d ${D}${includedir}/linux
    install -m 0644 ${S}/include/uapi/linux/drpai.h ${D}${includedir}/linux/
}

FILES:${PN}-dev += "${includedir}/linux/drpai.h"
