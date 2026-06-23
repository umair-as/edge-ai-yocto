# EDGE_OTA_BACKEND = "rauc" — RAUC binding.
#
# Pulled by edge-ai.conf when EDGE_OTA_BACKEND = "rauc". Binds:
#   - virtual-ota-uboot-env  → rauc-uboot-env  (manages BOOT_ORDER/x_LEFT)
#   - virtual-rauc-conf      → rauc-conf-edge  (distro-policy system.conf)
#   - WKS slot labels        → rootfsA / rootfsB (RAUC convention)
#   - IMAGE_INSTALL          → rauc daemon + grow-data oneshot + conf
#
# See ADR-0005 for the virtual-provider contract; a future
# edge-ota-mender.inc would bind the same virtuals to mender-* recipes
# with rootfs1/rootfs2 slot labels.

PREFERRED_RPROVIDER_virtual-ota-uboot-env = "rauc-uboot-env"

# meta-rauc's rauc-conf and rauc-conf-edge both claim
# virtual-rauc-conf; pin the distro-policy variant to silence
# "Multiple providers are available" at parse.
PREFERRED_RPROVIDER_virtual-rauc-conf = "rauc-conf-edge"

# RAUC slot labels — consumed by edge-rzv2l.wks.in via bitbake-time
# template expansion. WIC sets the partition ext4 label from --label,
# and the WKS sets that to ${EDGE_SLOT_*_LABEL}.
EDGE_SLOT_A_LABEL = "rootfsA"
EDGE_SLOT_B_LABEL = "rootfsB"

# RAUC userspace pulled into every image. The bundle recipe
# (edge-bundle) and the system.conf (rauc-conf-edge) are built
# separately; the image just needs the daemon + helpers.
IMAGE_INSTALL:append = " rauc rauc-conf-edge"

# /data first-boot growth. One mechanism for both layouts: edge-grow-data
# dispatches on the partition table at runtime (systemd-repart for GPT/eMMC,
# parted for MBR/eSD), so the same package ships regardless of EDGE_BOOT_TARGET.
IMAGE_INSTALL:append = " edge-grow-data"
