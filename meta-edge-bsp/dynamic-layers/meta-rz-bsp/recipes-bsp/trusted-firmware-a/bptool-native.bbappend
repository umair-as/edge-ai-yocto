# Wrynose port: meta-renesas's bptool-native.bb sets S = "${WORKDIR}/git",
# which wrynose's do_unpack hard-rejects ("S set by bitbake.conf in oe-core
# now works"). Override with the wrynose default; survives meta-renesas
# version bumps where a kas-patch would fail on file-checksum drift.
#
# bptool itself (tools/renesas/rz_boot_param/bptool.c) emits the correct
# 3584-byte eSD boot-parameter block natively in "esd" mode — its main
# loop writes the 512-byte bootparam struct 7 times when ESD_LOAD_OFFSET
# is selected. Meta-renesas's firmware-pack.bb consumes that output and
# deploys bl2_bp_esd-${MACHINE}.bin to DEPLOYDIR; WKS rawcopies it
# at sector 0. No custom regen needed.
S = "${UNPACKDIR}/${BP}"
