FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
            file://CVE-2026-10536.patch \
            file://CVE-2026-4873.patch \
            "

# The carried patch is the complete upstream fix for the HTTP/2 stream-
# dependency UAF. Its patch header is commit
# 469059cec7d4b3770318d61bf0787c8a6bff163a; the upstream fix is
# bfbff7852f050232edd3e5ca5c6bf2021c340f5a. Keep the recipe-level assertion
# after oe-core's conditional status, which otherwise marks the CVE unpatched
# whenever nghttp2 is enabled.
CVE_STATUS[CVE-2026-10536] = "backported-patch: carried curl commit 469059cec7d4b3770318d61bf0787c8a6bff163a; upstream fix bfbff7852f050232edd3e5ca5c6bf2021c340f5a removes stream-dependency tracking"
