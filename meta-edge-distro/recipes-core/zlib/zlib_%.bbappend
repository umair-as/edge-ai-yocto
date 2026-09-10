FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"

SRC_URI += "file://CVE-2026-85091.patch"

# Heap overflow reachable from gzprintf()/gzvprintf() after a non-blocking
# write stall: the stall branch set Z_BUF_ERROR but did not return, so the
# caller went on to index off strm->next_in while it still pointed into the
# caller's buffer. Carried from PR #1281 rather than authored locally; the
# same PR fixes the upstream report the CVE was raised from (issue #1256).
# No fixed release exists yet — upstream's newest tag is v1.3.2, which is
# the affected version — so this is carried until a release includes it.
#
# No CVE_STATUS here on purpose. The patch header carries `CVE: CVE-2026-85091`
# and cve-check derives the patched status from that. An explicit CVE_STATUS
# overrides the automatic detection, which means the shipped SBOM would report
# our assertion instead of the evidence: if the patch were ever dropped from
# SRC_URI, the override would keep claiming the CVE is fixed. Deriving it from
# the patch fails in the safe direction -- the CVE reappears as Unpatched.
