# Scarthgap→wrynose port: S = "${WORKDIR}/git/libmmngr/mmngr" →
# ${UNPACKDIR}/${BP}/libmmngr/mmngr. Subdir under the unpacked tree
# preserved; same QA-gate rationale as kernel-module-mmngr.bbappend.
S = "${UNPACKDIR}/${BP}/libmmngr/mmngr"

# mmngr_lib.inc hardcodes the scarthgap-era absolute path for the
# license file (file://${WORKDIR}/git/COPYING.MIT). Re-point to the
# wrynose unpack location at the git-checkout root, two dirs above S.
LIC_FILES_CHKSUM = "file://${UNPACKDIR}/${BP}/COPYING.MIT;md5=30a99e0d36a3da1f5cf93c070ad7888a"
