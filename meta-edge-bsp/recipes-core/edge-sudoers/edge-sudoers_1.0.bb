SUMMARY     = "sudo policy: %wheel password-required + optional NOPASSWD drop-in"
DESCRIPTION = "Ships /etc/sudoers.d/10-edge-wheel granting %wheel ALL=(ALL:ALL) \
ALL with password required. The -nopasswd sub-package adds a higher-numbered \
drop-in overriding %wheel to NOPASSWD; installed on edge-image-dev only."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = " \
    file://10-edge-wheel \
    file://15-edge-wheel-nopasswd \
"

S = "${UNPACKDIR}"

# sudo's /etc/sudoers includes "@includedir /etc/sudoers.d" by default
# (verified in OE-core's sudo recipe through wrynose). Drop-ins need
# 0440 owned by root:root or sudo refuses them as "world writable".
do_install() {
    install -d -m 0750 -o root -g root ${D}${sysconfdir}/sudoers.d
    install -m 0440 -o root -g root ${UNPACKDIR}/10-edge-wheel \
        ${D}${sysconfdir}/sudoers.d/10-edge-wheel
    install -m 0440 -o root -g root ${UNPACKDIR}/15-edge-wheel-nopasswd \
        ${D}${sysconfdir}/sudoers.d/15-edge-wheel-nopasswd
}

# Two output packages: -nopasswd carries the NOPASSWD override; main
# carries the password-required baseline. Using -nopasswd (not the
# conventional -dev) keeps the name semantic AND avoids colliding with
# defaults.bbclass's auto-PACKAGES (which already lists ${PN}-dev for
# headers / dev-libs).
PACKAGES =+ "${PN}-nopasswd"

FILES:${PN}-nopasswd = "${sysconfdir}/sudoers.d/15-edge-wheel-nopasswd"
FILES:${PN}          = "${sysconfdir}/sudoers.d/10-edge-wheel"

SUMMARY:${PN}-nopasswd     = "NOPASSWD override for %wheel (dev images only)"
DESCRIPTION:${PN}-nopasswd = "Drop-in overriding 10-edge-wheel to make %wheel \
passwordless. Installed by edge-image-dev; edge-image-base omits it."
RDEPENDS:${PN}-nopasswd    = "${PN}"

# Without this, do_package's QA check trips on the 0440 perm.
INSANE_SKIP:${PN}          = "rdepends"
INSANE_SKIP:${PN}-nopasswd = "rdepends"

# sudo itself must be in the image. Pulled by packagegroup-edge-base
# but tracked here too so the dependency is explicit if this recipe is
# consumed by other paths.
RDEPENDS:${PN} = "sudo"
