FILESEXTRAPATHS:prepend := "${THISDIR}/weston-init:"

# Upstream [Install] WantedBy=graphical.target is dormant since
# SYSTEMD_DEFAULT_TARGET=multi-user.target (edge-floor.inc). Symlink under
# multi-user.target.wants/ keeps auto-start; edge-defer.conf handles
# deferral, DRM probe gating, and the pam_systemd bypass.

SRC_URI:append = " \
    file://edge-defer.conf \
    file://edge-wallpaper.png \
"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/edge-defer.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/edge-defer.conf

    install -d ${D}${systemd_system_unitdir}/multi-user.target.wants
    ln -sf ../weston.service \
        ${D}${systemd_system_unitdir}/multi-user.target.wants/weston.service

    install -d ${D}${datadir}/weston
    install -m 0644 ${UNPACKDIR}/edge-wallpaper.png \
        ${D}${datadir}/weston/edge-wallpaper.png
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/weston.service.d/edge-defer.conf \
    ${systemd_system_unitdir}/multi-user.target.wants/weston.service \
    ${datadir}/weston/edge-wallpaper.png \
"
