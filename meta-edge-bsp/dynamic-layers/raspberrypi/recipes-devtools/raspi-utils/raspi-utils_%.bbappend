# Newer than the meta-raspberrypi pin (rpi-fw-crypto locking, rpi-eeprom-ab and
# pinctrl updates).
SRCREV = "e0484c848f9c9d1aecc7bd0738930db97bcf18df"

# At this SRCREV ovmerge is Python and imports ovmerge_engine.py; the layer
# recipe still packages it as a perl tool and leaves the engine in ${PN}.
FILES:${PN}-ovmerge += "${bindir}/ovmerge_engine.py"
RDEPENDS:${PN}-ovmerge:remove = "perl"
RDEPENDS:${PN}-ovmerge += "python3-core"
