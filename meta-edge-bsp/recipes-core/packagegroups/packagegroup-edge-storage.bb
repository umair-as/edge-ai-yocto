SUMMARY     = "Storage tooling: parted, dosfstools, f2fs-tools, fio"
DESCRIPTION = "Partition/filesystem manipulation and storage benchmarking on \
dev images: parted, dosfstools, f2fs-tools, fio. f2fs-tools and fio come \
from meta-openembedded."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
RDEPENDS:${PN} = " \
    parted \
    dosfstools \
    f2fs-tools \
    fio \
"
