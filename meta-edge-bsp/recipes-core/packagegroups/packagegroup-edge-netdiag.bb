SUMMARY     = "Network diagnosis: ss/tc/bridge, tcpdump, iperf3, ethtool, socat"
DESCRIPTION = "iproute2-{ss,tc,bridge,nstat}, tcpdump, iperf3, ethtool, socat. \
OE-Core ships ss/tc/bridge as separate sub-packages — main iproute2 only \
pulls iproute2-ip, so they must be explicit RDEPENDS."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup
RDEPENDS:${PN} = " \
    iproute2-ss \
    iproute2-tc \
    iproute2-bridge \
    iproute2-nstat \
    tcpdump \
    iperf3 \
    socat \
    ethtool \
"
