FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
            file://CVE-2025-52194.patch \
            file://CVE-2026-37555.patch \
            "

