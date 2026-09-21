SUMMARY     = "Crypto support library for OP-TEE plat-rz SCE driver"
DESCRIPTION = "Static archive providing the symbols required by OP-TEE's \
plat-rz Secure IP driver on RZ/V2L. Consumed at OP-TEE build time when \
CFG_RZ_SCE=y."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "libs"
LICENSE     = "CLOSED"

require include/dev-define.inc

SRC_URI = "file://renesas-secureip-library-${DEV}.tar.gz"

S = "${UNPACKDIR}/renesas-secureip-library"

do_install() {
    install -d ${D}${includedir}
    install -d ${D}${libdir}
    install -m 0644 ${S}/include/*.h ${D}${includedir}
    install -m 0644 ${S}/lib*        ${D}${libdir}
}

FILES:${PN} = "${libdir} ${includedir}"
