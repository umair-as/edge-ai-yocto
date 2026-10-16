SUMMARY = "Base image: A/B verity rootfs with the EDGE AI OS brand splash"
DESCRIPTION = "Minimal bootable tier of the edge-ai distro: A/B verity rootfs, \
psplash brand splash, and Weston when EDGE_ENABLE_DISPLAY=1. edge-image-dev and \
edge-image-prod are the extended tiers."
HOMEPAGE = "https://github.com/umair-as/edge-ai-yocto"
SECTION = "base"
LICENSE = "MIT"

inherit edge-ab-image

WKS_SEARCH_PATH = "${THISDIR}/files/wic"

# Bring-up baseline. Tier-flexible: EDGE_PROFILE comes from the invocation
# (the Makefile `base` target selects dev; distro default is dev). No tier
# assertion here, so base can also be built under prod for a lean bundle.
# The "prod tier" with explicit hardening lives in edge-image-prod.bb.
