FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
            file://CVE-2026-10536.patch \
            file://CVE-2026-4873.patch \
            "

# The carried patch is the complete upstream fix for the HTTP/2 stream-
# dependency UAF.  Keep the recipe-level assertion after oe-core's conditional
# status, which otherwise marks the CVE unpatched whenever nghttp2 is enabled.
CVE_STATUS[CVE-2026-10536] = "backported-patch: upstream curl commit bfbff7852f050232edd3e5ca5c6bf2021c340f5; stream-dependency tracking is removed"
