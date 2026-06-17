SUMMARY = "edge-ai-yocto v0 base image: Weston + EDGE AI OS brand splash."
DESCRIPTION = "Minimal bootable tier. Verifies the wrynose 6.0 + Renesas \
vendor BSP (CIP-aligned linux-renesas) + custom 'edge-ai' distro composition. \
Dev and prod tiers will extend this baseline once boot is confirmed."

require recipes-core/images/edge-image-common.inc

# Bring-up baseline. EDGE_PROFILE is unset; the distro's features.inc
# default ("prod") applies. The "prod tier" with explicit hardening
# lives in edge-image-prod.bb.
