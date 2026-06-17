SUMMARY     = "OP-TEE userspace: client + tee-supplicant + xtest slice"
DESCRIPTION = "${PN} carries libteec, tee-supplicant, and optee-examples. \
${PN}-test adds optee-test/xtest (~10 MB; dev images only). Gated by \
COMPATIBLE_MACHINE=smarc-rzv2l — only that board wires BL32."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "bootloaders"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "smarc-rzv2l"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
PACKAGES = " \
    ${PN} \
    ${PN}-test \
"

RDEPENDS:${PN} = " \
    optee-client \
    optee-examples \
"

RDEPENDS:${PN}-test = "optee-test"
