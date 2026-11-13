SUMMARY     = "Production image: hardened, locked-down tier"
DESCRIPTION = "Production tier with an authenticated read-only rootfs, no \
package management, and observability disabled by default."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"

inherit edge-ab-image

WKS_SEARCH_PATH = "${THISDIR}/files/wic"

# Bootchain updaters, named by the board (EDGE_MACHINE_BOOTLOADER_UPDATE_INSTALL).
# Off by default: single-copy bootchain storage. BOOTLOADER_UPDATE=1.
EDGE_ENABLE_BOOTLOADER_UPDATE ?= "0"
IMAGE_INSTALL:append = "${@bb.utils.contains('EDGE_ENABLE_BOOTLOADER_UPDATE', '1', ' ' + (d.getVar('EDGE_MACHINE_BOOTLOADER_UPDATE_INSTALL') or ''), '', d)}"

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
            "requires EDGE_PROFILE=prod (got '%s'); build with 'make prod'" % p)
}
