# Scarthgap→wrynose port: S = "${WORKDIR}/git" → ${UNPACKDIR}/${BP};
# patch-status demoted (vendor patches without Upstream-Status header).
# See kernel-module-mmngr.bbappend for the full rationale.
S = "${UNPACKDIR}/${BP}"
ERROR_QA:remove = "patch-status"

# Hand-installed .ko: signed here so it loads under CONFIG_MODULE_SIG_FORCE.
require recipes-kernel/include/edge-sign-kernel-module.inc
EDGE_SIGN_MODULES = "mmngrbuf"
