SUMMARY     = "Production image: hardened, locked-down tier"
DESCRIPTION = "Production tier. profile-prod.inc removes package-management \
and defaults observability off. Reserve here for further prod tightening \
(read-only-rootfs, IMAGE_FSTYPES trimming, etc.) as the security harvest lands."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"

inherit edge-ab-image

WKS_SEARCH_PATH = "${THISDIR}/files/wic"

# Prod tier. EDGE_PROFILE is resolved at distro-parse from the environment
# (make prod exports it); setting it here would be too late to steer the
# distro's `require edge-profile-${EDGE_PROFILE}.inc`. Read it and self-skip
# on a tier/image mismatch (SkipRecipe, not bb.fatal — see edge-image-dev.bb).
# This guards against a bare `bitbake edge-image-prod` building under the dev
# default: the recipe becomes unbuildable with the reason shown.
python () {
    p = d.getVar('EDGE_PROFILE')
    if p != 'prod':
        raise bb.parse.SkipRecipe(
            "requires EDGE_PROFILE=prod (got '%s'); build with 'make prod' "
            "or set EDGE_PROFILE=prod" % p)
}
