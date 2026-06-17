# Wrynose port: meta-renesas's flash-writer.bb sets
#   S:rzg2l-family = "${WORKDIR}/git"
# (override-syntax form, distinct from the unsuffixed S = "..." in
# u-boot-renesas.inc / TF-A / bptool-native). The machine-override
# `:rzg2l-family` beats a plain `S =` in bitbake's priority, so the
# bbappend has to match the same override form to win.
#
# Scope: flash-writer is a SCIF-download recovery tool for XSPI/QSPI
# flash programming — not in our SD/eMMC boot path. But
# rzg2l-family.inc adds it to EXTRA_IMAGEDEPENDS and smarc-rzv2l.conf
# adds flash-writer:do_deploy to do_image_wic[depends], so WIC won't
# assemble without it. Fix at this layer.
S:rzg2l-family = "${UNPACKDIR}/${BP}"
