# Cross-cutting image policy for every edge-* image tier.
#
# Floor that holds true regardless of storage layout. A/B-slot semantics
# (shared /boot, EDGE_BOOT_* contract, OTA-backend parse gate) live in
# edge-ab-image.bbclass which inherits this. See ADR-0005.

inherit core-image
# edge-rootfs writes /etc/buildinfo at do_rootfs postprocess so every
# image carries an identity manifest. Lives in meta-edge-distro/classes/
# (distro-owned, not BSP-owned).
inherit edge-rootfs
# Labels the rootfs via setfiles at image-time and drops /.autorelabel
# for first-boot fallback. Self-gates on DISTRO_FEATURES contains
# "selinux"; no-op on distros without it.
inherit selinux-image

# Custom WICVARS appends live per-machine in kas/machines/<board>.yml,
# alongside the variables they expose (e.g. RZ/V2L's FIP_WIC_OFFSET).
# WIC only expands ${VAR} inside .wks files for variables listed in WICVARS;
# the oe-core default list (image_types_wic.bbclass) covers the universal
# set, anything board-specific gets added on the machine overlay.

# Common IMAGE_FEATURES for every edge tier.
#   splash             — psplash, branded via meta-edge-distro/recipes-core/psplash
#   ssh-server-openssh — operator access
#   package-management — dnf/rpm at runtime (removed by edge-profile-prod.inc)
#   weston             — Wayland compositor (gated by EDGE_ENABLE_DISPLAY)
IMAGE_FEATURES += " \
    splash \
    ssh-server-openssh \
    package-management \
"
IMAGE_FEATURES += "${@bb.utils.contains('EDGE_ENABLE_DISPLAY', '1', 'weston', '', d)}"
# Login policy lives elsewhere — see meta-edge-distro/recipes-core/users/
# and the hardening fragments. Don't add IMAGE_FEATURES like
# empty-root-password / allow-empty-password / allow-root-login /
# serial-autologin-root here. They're CRA-incompatible defaults.

IMAGE_LINGUAS = "en-us"

# Hard-assign IMAGE_FSTYPES (not ?=). oe-core's bitbake.conf claims the
# variable with `?= "tar.zst"` before this file is processed; a weak
# default here loses the race and no WIC gets emitted.
#
# wic.zst over wic.bz2/wic.gz: zstd compresses ~3x faster than gzip and
# ~6x faster than bzip2 at a better ratio than gzip; bmaptool reads it
# natively. Build-time win every iteration.
IMAGE_FSTYPES = "wic.zst wic.bmap ext4 tar.gz"

# meta-renesas's rz-common.inc does
#   IMAGE_FSTYPES:append = " tar.gz tar.bz2 ext4 wic.gz wic.bmap"
# Late-binding :append wins over the = above; without this :remove
# wic.gz and tar.bz2 are built unnecessarily (~1.5-2.5 min each).
IMAGE_FSTYPES:remove = "wic.gz tar.bz2"

# WIC's imager-level update_fstab() appends one /dev/mmcblk0pN line per WKS
# partition to /etc/fstab even when partitions carry --no-fstab-update (that
# flag is per-partition install-time, not merge-time). systemd-fstab-generator
# then fails on the duplicates with "already exists. Duplicate entry in
# '/etc/fstab'?". The CLI flag is what skips update_fstab() entirely.
WIC_CREATE_EXTRA_ARGS:append = " --no-fstab-update"

# Common runtime — universal across every edge image tier. The full list
# (edge-banner, edge-systemd-presets, slot udev, u-boot env tooling)
# lives in packagegroup-edge-base; the OTA backend's packages come from
# the distro's edge-ota-${EDGE_OTA_BACKEND}.inc.
CORE_IMAGE_EXTRA_INSTALL += " packagegroup-edge-base"

# Observability tooling (htop, sysstat, trace-cmd, ...). Toggled by
# EDGE_ENABLE_OBSERVABILITY (profile-keyed default: prod=0, dev=1).
CORE_IMAGE_EXTRA_INSTALL += "${@bb.utils.contains('EDGE_ENABLE_OBSERVABILITY', '1', ' packagegroup-edge-observability', '', d)}"

# Container userspace runtime. Default off; recipe to be added when
# the toggle is flipped (current consumers: dev images that opt in).
CORE_IMAGE_EXTRA_INSTALL += "${@bb.utils.contains('EDGE_ENABLE_CONTAINERS', '1', ' packagegroup-edge-containers', '', d)}"

# OP-TEE userspace (libteec + tee-supplicant + optee-examples) is bundled by
# packagegroup-edge-optee. The packagegroup declares COMPATIBLE_MACHINE on
# itself, but BitBake does NOT fail-soft on a COMPATIBLE_MACHINE-incompatible
# dependency — a non-rzv2l image listing this packagegroup would error at
# parse with "Nothing provides packagegroup-edge-optee". Hence the
# machine-conditional append at the image level.
CORE_IMAGE_EXTRA_INSTALL:append:smarc-rzv2l = " packagegroup-edge-optee"

# mtd-utils brings flashcp/flash_erase/nandwrite for the BL2/FIP SPI flash
# partitions exposed by mtd0/mtd1. Needed for in-place FIP updates without
# pulling the SD card.
CORE_IMAGE_EXTRA_INSTALL:append:smarc-rzv2l = " mtd-utils"
