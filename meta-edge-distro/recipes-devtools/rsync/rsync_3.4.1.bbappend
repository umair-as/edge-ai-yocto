FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
            file://CVE-2026-41035.patch \
            file://CVE-2026-43618.patch \
            file://CVE-2026-45232.patch \
            "
