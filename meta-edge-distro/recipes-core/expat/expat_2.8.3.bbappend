FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://CVE-2026-76956.patch;striplevel=2 \
            file://CVE-2026-102633.patch;striplevel=2 \
"
