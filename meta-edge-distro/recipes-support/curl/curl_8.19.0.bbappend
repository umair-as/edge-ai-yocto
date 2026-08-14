FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
            file://CVE-2026-10536.patch \
            file://CVE-2026-4873.patch \
            "

