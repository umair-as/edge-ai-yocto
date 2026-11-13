SUMMARY     = "RAUC custom bootloader backend over systemd-boot boot counting"
DESCRIPTION = "Installs the RAUC custom backend that keeps A/B slot state in the names of \
boot-counted UKIs on the ESP, and masks the systemd units that would confirm a \
slot or replace the ESP's loader outside RAUC."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "console/utils"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://edge-sdboot-backend \
    file://80-edge-sdboot.preset \
"

S = "${UNPACKDIR}"

inherit allarch

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/edge-sdboot-backend ${D}${libexecdir}/edge-sdboot-backend

    # systemd-boot exports LoaderBootCountPath for a counted entry, and the
    # bless-boot generator would then drop the counter after boot-complete.target,
    # confirming a slot without RAUC and without prevent-late-fallback.
    install -d ${D}${sysconfdir}/systemd/system
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/systemd-bless-boot.service

    install -d ${D}${systemd_unitdir}/system-preset
    install -m 0644 ${UNPACKDIR}/80-edge-sdboot.preset ${D}${systemd_unitdir}/system-preset/
}

FILES:${PN} = " \
    ${libexecdir}/edge-sdboot-backend \
    ${sysconfdir}/systemd/system/systemd-bless-boot.service \
    ${systemd_unitdir}/system-preset/80-edge-sdboot.preset \
"

# bash 4+ for associative arrays; flock from util-linux; the rest coreutils.
RDEPENDS:${PN} = " \
    bash \
    coreutils \
    util-linux-flock \
"
