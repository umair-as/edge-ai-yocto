# EDGE AI OS static pre/post-login surfaces.
#
# Replaces base-files' built-in /etc/issue, /etc/issue.net, and /etc/motd
# with EDGE AI OS-branded versions rendered at image-build time from
# templates that live next to this bbappend. Build-baked substitutions:
# @DISTRO_NAME@, @DISTRO_VERSION@, @EDGE_BUILD_DATE@.
#
# Rationale: see edge-banner_1.0.bb for the full design. Short form:
# the previous edge-banner.service rebuilt these surfaces at every
# boot from D-Bus + `rauc` forks, costing ~3.7 s on the boot critical
# chain. Split: static (here, build-time, $0 runtime cost)
# + dynamic appendix (/etc/profile.d/edge-motd-dynamic.sh, $50 ms at
# login). This file is the static half.
#
# `BASEFILESISSUEINSTALL = ""` in edge.conf turns off base-files'
# built-in do_install_basefilesissue task that would otherwise re-render
# /etc/issue and /etc/issue.net during do_install — prevents the edge
# bbappend's templates from being clobbered.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
    file://fstab \
    file://edge-issue.tmpl \
    file://edge-issue-net.tmpl \
    file://edge-motd.tmpl \
"

# Render build-time substitutions into the templates, then
# move the rendered files into ${D}${sysconfdir} overwriting base-files'
# placeholder motd (issue/issue.net are not rendered by base-files
# because BASEFILESISSUEINSTALL is empty — see edge.conf).
do_install:append () {
    # Install edge fstab over base-files' stock one — adds LABEL=boot
    # and LABEL=data so systemd-fstab-generator creates the matching
    # .mount units. Without this, edge-persistence's binds and the
    # identity-persist services skip on ConditionPathIsMountPoint=/data.
    install -m 0644 ${UNPACKDIR}/fstab ${D}${sysconfdir}/fstab

    # Templates carry ANSI colour codes as plain "[N;Nm" so they stay
    # text-editable; sed prefixes each match with the literal ESC byte
    # (0x1b) so login(1) / sshd render them as colour escapes rather than
    # printing them verbatim. issue(5) treats only \X placeholders; \033
    # is NOT one of them, which is why the byte has to be real on disk.
    # Applied to issue + issue-net (login + sshd surfaces); motd already
    # ships ESC bytes embedded in the template.
    sed -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
        -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
        -e "s|@EDGE_BUILD_DATE@|${EDGE_BUILD_DATE}|g" \
        -e 's|\[\([0-9;]\+\)m|\x1b[\1m|g' \
        ${UNPACKDIR}/edge-issue.tmpl > ${D}${sysconfdir}/issue

    sed -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
        -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
        -e "s|@EDGE_BUILD_DATE@|${EDGE_BUILD_DATE}|g" \
        -e 's|\[\([0-9;]\+\)m|\x1b[\1m|g' \
        ${UNPACKDIR}/edge-issue-net.tmpl > ${D}${sysconfdir}/issue.net

    sed -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
        -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
        -e "s|@EDGE_BUILD_DATE@|${EDGE_BUILD_DATE}|g" \
        ${UNPACKDIR}/edge-motd.tmpl > ${D}${sysconfdir}/motd

    chmod 0644 ${D}${sysconfdir}/issue \
               ${D}${sysconfdir}/issue.net \
               ${D}${sysconfdir}/motd
}
