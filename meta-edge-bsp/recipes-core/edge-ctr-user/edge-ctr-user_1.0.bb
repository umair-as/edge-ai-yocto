SUMMARY     = "Dedicated rootless-container service account (edge-ctr)"
DESCRIPTION = "System account that runs the DRP-AI inference container under \
rootless Podman. No interactive login; static uid/gid 608; subordinate id \
ranges and linger enabled by design; home + container storage on /data so state \
survives RAUC slot swaps. Separates the container runtime principal from the \
interactive devel login."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://edge-ctr.tmpfiles"

inherit useradd

S = "${UNPACKDIR}"

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r edge-ctr"

# uid/gid 608 injected by useradd-staticids from files/{passwd,group}. System
# account, no interactive login, home on /data (a runtime mount, so
# --no-create-home; the tmpfiles entry creates it after data.mount). The
# render supplementary membership is added at image assembly (edge-users.inc)
# not here: render is created by another recipe and may be absent at this
# useradd, which would fail the whole account creation.
USERADD_PARAM:${PN} = " \
    --system --gid edge-ctr \
    --home-dir /data/edge-ctr --no-create-home \
    --shell /usr/sbin/nologin \
    --comment 'Edge container runtime principal' edge-ctr \
"

ALLOW_EMPTY:${PN} = "1"
RPROVIDES:${PN} += "edge-ctr-user"

do_install() {
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/edge-ctr.tmpfiles \
        ${D}${nonarch_libdir}/tmpfiles.d/edge-ctr.conf
}

# Subordinate uid/gid ranges for rootless podman as edge-ctr. Distinct from
# devel's 100000 block. /etc/sub{u,g}id are owned by shadow, so append in
# postinst rather than shipping the files (a shipped copy collides at do_rootfs).
pkg_postinst:${PN}() {
    for f in subuid subgid; do
        grep -q '^edge-ctr:200000:' $D${sysconfdir}/$f 2>/dev/null || \
            echo 'edge-ctr:200000:65536' >> $D${sysconfdir}/$f
    done
}

FILES:${PN} = "${nonarch_libdir}/tmpfiles.d/edge-ctr.conf"
