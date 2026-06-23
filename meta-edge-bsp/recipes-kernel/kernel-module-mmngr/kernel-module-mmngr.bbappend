# meta-renesas's kernel-module-mmngr.bb sets S = "${WORKDIR}/git" —
# wrynose's do_qa_unpack rejects this (S is set by bitbake.conf to
# ${UNPACKDIR}/${BP} in modern oe-core). Override via bbappend so it
# survives meta-renesas version bumps.
S = "${UNPACKDIR}/${BP}"

# Vendor patches lack the Upstream-Status header that wrynose's do_patch
# postfunc requires. patch-status demoted from ERROR_QA here rather than
# carrying header-only forks of meta-renesas's patches under our files/.
ERROR_QA:remove = "patch-status"
