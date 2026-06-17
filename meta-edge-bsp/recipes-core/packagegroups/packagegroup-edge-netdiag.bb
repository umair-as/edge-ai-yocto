SUMMARY     = "Network diagnosis: tcpdump, iperf3, ethtool, socat"
DESCRIPTION = "tcpdump (capture), iperf3 (throughput), ethtool (link/PHY), \
socat (socket bridging). nmap-ncat omitted on NPSL grounds; busybox `nc` \
covers quick TCP probes."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
RDEPENDS:${PN} = " \
    tcpdump \
    iperf3 \
    socat \
    ethtool \
"
