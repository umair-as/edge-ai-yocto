# EDGE_OTA_BACKEND = "rauc" — RAUC wiring.
#
# Required by edge-ai.conf when EDGE_OTA_BACKEND = "rauc". Adds the
# RAUC userspace to every image; the slot model (slot udev, U-Boot env
# tooling, A/B partition layout) is backend-agnostic and stays in the
# base packagegroup and the WIC.

# meta-rauc's rauc-conf and rauc-conf-edge both claim
# virtual-rauc-conf; pin the distro-policy variant to silence
# "Multiple providers are available" at parse.
PREFERRED_RPROVIDER_virtual-rauc-conf = "rauc-conf-edge"

# RAUC userspace pulled into every image. The bundle recipe
# (edge-bundle) and the system.conf (rauc-conf-edge) are built
# separately; the image just needs the daemon + helpers.
IMAGE_INSTALL:append = " rauc rauc-grow-data-part rauc-conf-edge"
