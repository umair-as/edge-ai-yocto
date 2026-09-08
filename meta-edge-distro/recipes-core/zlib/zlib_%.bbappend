FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"

SRC_URI += "file://CVE-2026-85091.patch"

# Heap overflow reachable from gzprintf()/gzvprintf() after a non-blocking
# write stall: the stall branch set Z_BUF_ERROR but did not return, so the
# caller went on to index off strm->next_in while it still pointed into the
# caller's buffer. Carried from PR #1281 rather than authored locally; the
# same PR fixes the upstream report the CVE was raised from (issue #1256).
# No fixed release exists yet — upstream's newest tag is v1.3.2, which is
# the affected version — so this is carried until a release includes it.
CVE_STATUS[CVE-2026-85091] = "fix-file-included: carried madler/zlib PR #1281 commit bf3364d56678ae12892168d1ee22ac4e13ef80a3; no upstream release carries the fix yet"
