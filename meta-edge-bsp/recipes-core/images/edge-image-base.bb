SUMMARY = "edge-ai-yocto v0 base image: Weston + EDGE AI OS brand splash."
DESCRIPTION = "Minimal bootable tier. Verifies the wrynose 6.0 + Renesas \
vendor BSP (CIP-aligned linux-renesas) + custom 'edge-ai' distro composition. \
Dev and prod tiers will extend this baseline once boot is confirmed."
LICENSE = "MIT"

inherit edge-ab-image

WKS_SEARCH_PATH = "${THISDIR}/files/wic"

# Bring-up baseline. Tier-flexible: EDGE_PROFILE comes from the invocation
# (the Makefile `base` target selects dev; distro default is dev). No tier
# assertion here, so base can also be built under prod for a lean bundle.
# The "prod tier" with explicit hardening lives in edge-image-prod.bb.
