SUMMARY     = "Edge base runtime: brand, slot udev, U-Boot env, hardening"
DESCRIPTION = "Runtime packages pulled into every edge image tier — brand \
assets, systemd presets, sudo/sysctl/journald hardening, audit, slot udev \
rules, U-Boot env tooling. OTA backend packages live in the distro's \
edge-ota-${EDGE_OTA_BACKEND}.inc."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

RDEPENDS:${PN} = " \
    edge-systemd-presets \
    edge-banner \
    edge-slot-udev \
    edge-sudoers \
    edge-sysctl-hardening \
    edge-persistence \
    edge-journald-hardening \
    edge-pstore-persist \
    edge-audit \
    packagegroup-edge-security \
    networkmanager \
    edge-network-profiles \
    virtual-ota-uboot-env \
    u-boot-fw-utils \
"
