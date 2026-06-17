FILESEXTRAPATHS:prepend := "${THISDIR}/weston-init:"

# Defer weston off the boot critical chain. See edge-defer.conf for the
# rationale; SYSTEMD_DEFAULT_TARGET = "multi-user.target" in
# meta-edge-distro/conf/distro/edge-ai.conf is the paired policy knob.
#
# Upstream weston.service has [Install] WantedBy=graphical.target only.
# graphical.target is not the default (SYSTEMD_DEFAULT_TARGET = multi-user.target);
# upstream Install link is never activated. Add multi-user.target.wants symlink so
# weston still auto-starts. The drop-in then adds After=multi-user.target
# so the compositor starts AFTER multi-user is active — boot-complete is
# measured against multi-user.target, weston runs in parallel with login.

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
