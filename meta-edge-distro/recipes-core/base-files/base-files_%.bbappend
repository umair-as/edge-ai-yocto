# EDGE AI OS static pre/post-login surfaces.
#
# Replaces base-files' built-in /etc/issue, /etc/issue.net, and /etc/motd
# with EDGE AI OS-branded versions rendered at image-build time from
# templates that live next to this bbappend. Build-baked substitutions:
# @DISTRO_NAME@, @DISTRO_VERSION@, @EDGE_BUILD_DATE@.
#
# This file is the static, build-time half of the login surfaces; the
# dynamic appendix is edge-banner's /etc/profile.d/edge-motd-dynamic.sh,
# run at login, which keeps D-Bus and rauc calls off the boot path.
#
# `BASEFILESISSUEINSTALL = ""` in edge-floor.inc turns off base-files'
# built-in do_install_basefilesissue task that would otherwise re-render
# /etc/issue and /etc/issue.net during do_install — prevents the edge
# bbappend's templates from being clobbered.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
    file://edge-issue.tmpl \
    file://edge-issue-net.tmpl \
    file://edge-motd.tmpl \
"

# Render build-time substitutions into the templates, then
# move the rendered files into ${D}${sysconfdir} overwriting base-files'
# placeholder motd (issue/issue.net are not rendered by base-files
# because BASEFILESISSUEINSTALL is empty — see edge-floor.inc).
do_install:append () {
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
