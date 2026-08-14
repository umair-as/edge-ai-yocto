SUMMARY     = "OP-TEE secure-world userspace for boards that wire BL32"
DESCRIPTION = "${PN} pulls the normal-world side of the OP-TEE stack: client \
libraries, supplicant, and the Trusted Applications selected for this distro. \
${PN}-test adds the OP-TEE test suite (~10 MB), for dev images only."
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

# Baseline: the client library and tee-supplicant, without which the secure
# world is unreachable from Linux. Everything else about this packagegroup is
# selectable, so nothing lands in an image that did not ask for it.
RDEPENDS:${PN} = "optee-client"

# Demo TAs, loadable from optee_armtz and signed with the devkit's default key.
# Off by default: no workload calls them, and every TA in the image is secure-world
# attack surface and a CVE-tracking obligation.
RDEPENDS:${PN} += "${@bb.utils.contains('EDGE_ENABLE_OPTEE_EXAMPLES','1',' optee-examples','',d)}"

RDEPENDS:${PN}-test = "optee-test"
