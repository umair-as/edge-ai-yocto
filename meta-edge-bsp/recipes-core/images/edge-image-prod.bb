SUMMARY     = "Production image: hardened, locked-down tier"
DESCRIPTION = "Production tier. profile-prod.inc removes package-management \
and defaults observability off. Reserve here for further prod tightening \
(read-only-rootfs, IMAGE_FSTYPES trimming, etc.) as the security harvest lands."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"

require recipes-core/images/edge-image-common.inc

# Prod tier. Pulls edge-profile-prod.inc via the distro's require chain
# (OVERRIDES picks up :prod, package-management is removed, observability
# defaults off).
EDGE_PROFILE = "prod"
