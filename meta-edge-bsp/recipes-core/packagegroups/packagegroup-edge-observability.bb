SUMMARY     = "Observability: profilers, tracers, system introspection"
DESCRIPTION = "htop, iotop, lsof, sysstat (sar/iostat/pidstat), trace-cmd, \
systemd-analyze, stress-ng. Complements oe-core's tools-profile IMAGE_FEATURE \
(perf, lttng-tools)."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
RDEPENDS:${PN} = " \
    htop \
    iotop \
    kernel-dev \
    kernel-hardening-checker \
    lsof \
    sysstat \
    trace-cmd \
    systemd-analyze \
    stress-ng \
"
