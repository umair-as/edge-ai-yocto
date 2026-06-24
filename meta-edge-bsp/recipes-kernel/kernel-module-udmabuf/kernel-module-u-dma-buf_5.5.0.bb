SUMMARY     = "u-dma-buf: user-space mappable DMA buffer kernel module"
DESCRIPTION = "ikwzm u-dma-buf out-of-tree driver. Exports CMA-backed dma-buf \
regions to userspace (/dev/udmabuf0) for zero-copy V4L2 -> DRP-AI pipelines; \
device-tree instantiated against the image_buf0 shared-dma-pool."
HOMEPAGE    = "https://github.com/ikwzm/udmabuf"
BUGTRACKER  = "https://github.com/ikwzm/udmabuf/issues"
SECTION     = "kernel"
LICENSE     = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=bebf0492502927bef0741aa04d1f35f5"

inherit module

SRC_URI = "git://github.com/ikwzm/udmabuf.git;protocol=https;branch=master"
SRCREV  = "15bcde3cb960321e99983e227aeacc5807888333"
PV = "5.5.0"

# ikwzm's Makefile out-of-tree path re-derives ARCH/CROSS_COMPILE from the build
# host's uname (-> x86); force the cross target. KERNEL_SRC, MODLIB and the
# first ('all') make target come from module.bbclass.
EXTRA_OEMAKE += "ARCH=arm64 CROSS_COMPILE=${TARGET_PREFIX}"

# u-dma-buf upstream tracks recent kernels natively (LINUX_VERSION_CODE guards
# up to 6.18); no vendor patch needed on 6.12.
COMPATIBLE_MACHINE = "smarc-rzv2l"

KERNEL_MODULE_AUTOLOAD += "u-dma-buf"
