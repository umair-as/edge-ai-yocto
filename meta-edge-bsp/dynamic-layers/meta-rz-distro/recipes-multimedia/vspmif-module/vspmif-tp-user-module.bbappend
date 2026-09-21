# Scarthgap→wrynose port: S = "${WORKDIR}/git" → ${UNPACKDIR}/${BP}.
# See kernel-module-mmngr.bbappend for the rationale.
S = "${UNPACKDIR}/${BP}"
