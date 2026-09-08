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

# A verity root cannot fall back to first-boot relabelling: changing xattrs or
# deleting /.autorelabel would invalidate the Merkle tree. Override the
# upstream helper so image-time labelling is mandatory and no package-provided
# fallback marker reaches do_image_verity.
selinux_set_labels() {
    if [ -f ${IMAGE_ROOTFS}/${sysconfdir}/selinux/config ]; then
        pol_type=$(sed -n -e "s&^SELINUXTYPE[[:space:]]*=[[:space:]]*\([0-9A-Za-z_]\+\)&\1&p" \
            ${IMAGE_ROOTFS}/${sysconfdir}/selinux/config)
        # setfiles validates contexts against the build host's loaded policy
        # whenever one exists, so a host running SELinux rejects target types
        # absent from its own policy (refpolicy's mdadm_runtime_t, l2tpd_runtime_t
        # against Fedora's targeted policy) while a host without SELinux loaded
        # skips validation entirely and passes. -c pins validation to the target
        # policy, making the result independent of the build host.
        pol_bin=$(ls ${IMAGE_ROOTFS}/${sysconfdir}/selinux/${pol_type}/policy/policy.* \
            2>/dev/null | sort -V | tail -1)
        if [ -z "$pol_bin" ]; then
            bbfatal "No SELinux policy binary under ${sysconfdir}/selinux/${pol_type}/policy/"
        fi
        if ! setfiles -m -r ${IMAGE_ROOTFS} -c "$pol_bin" \
            ${IMAGE_ROOTFS}/${sysconfdir}/selinux/${pol_type}/contexts/files/file_contexts \
            ${IMAGE_ROOTFS}; then
            bbfatal "SELinux image-time labelling failed; dm-verity forbids first-boot relabelling"
        fi
        rm -f ${IMAGE_ROOTFS}/.autorelabel
    fi
}

# Custom WICVARS appends live per-machine in kas/machines/<board>.yml,
# alongside the variables they expose (e.g. RZ/V2L's FIP_WIC_OFFSET).
# WIC only expands ${VAR} inside .wks files for variables listed in WICVARS;
# the oe-core default list (image_types_wic.bbclass) covers the universal
# set, anything board-specific gets added on the machine overlay.

# Common IMAGE_FEATURES for every edge tier.
#   splash             — psplash, branded via meta-edge-distro/recipes-core/psplash
#   ssh-server-openssh — operator access
#   package-management — package queries on immutable dev/base images
#                        (removed by edge-profile-prod.inc)
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

# Board contract + accelerator selection, both fail-closed.
#
# The board check exists because a missing conf/machine/include/edge-board-
# ${MACHINE}.inc is otherwise completely silent (bitbake logs a failed soft
# include at debug2), and the values it carries -- slot devices written into
# the signed verity table, FIP offsets, FIT load addresses -- fail as a
# green build producing an unbootable image rather than as an error.
#
# The accelerator check refuses a machine/accelerator pair the board does not
# declare. Building without the accelerator is deliberately NOT the fallback:
# an image that silently lacks its accelerator is the failure this prevents.
python () {
    if not d.getVar('EDGE_BOARD_INC'):
        bb.fatal(
            "No board data for MACHINE = '%s'.\n"
            "  Expected: conf/machine/include/edge-board-%s.inc in a composed layer\n"
            "  (meta-edge-bsp owns these). It sets the slot devices, the\n"
            "  accelerator allowlist and the machine's extra image content.\n"
            "  A missing board file is silent in bitbake, hence this check."
            % (d.getVar('MACHINE'), d.getVar('MACHINE')))

    for entry in (d.getVar('EDGE_ACCEL_SUPPLEMENTARY_GROUPS') or '').split():
        if ':' not in entry or not all(entry.split(':', 1)):
            bb.fatal(
                "EDGE_ACCEL_SUPPLEMENTARY_GROUPS entry '%s' is malformed.\n"
                "  Expected \"group:user\" per entry, space separated."
                % entry)

    accel = (d.getVar('EDGE_ACCEL') or 'none').strip()
    if accel == 'none':
        return
    supported = (d.getVar('EDGE_ACCEL_SUPPORTED') or '').split()
    if accel not in supported:
        bb.fatal(
            "EDGE_ACCEL = '%s' is not supported on MACHINE = '%s'.\n"
            "  This machine declares EDGE_ACCEL_SUPPORTED = '%s'.\n"
            "  Either compose the matching machine, or drop the\n"
            "  kas/accel/%s.yml fragment from the composition.\n"
            "  Building without the accelerator is NOT the fallback: an image\n"
            "  that silently lacks its accelerator is the failure this refuses."
            % (accel, d.getVar('MACHINE'), ' '.join(supported), accel))
}

# Accelerator packagegroup, named by derivation so a new vendor needs no edit
# here. Empty when EDGE_ACCEL is "none".
CORE_IMAGE_EXTRA_INSTALL += "${@'' if (d.getVar('EDGE_ACCEL') or 'none') == 'none' else ' packagegroup-edge-accel-' + d.getVar('EDGE_ACCEL')}"

# Every kernel module in the image must carry a signature trailer. The image
# is built with MODULE_SIG_FORCE, so an unsigned .ko is a module that silently
# fails to load on the target rather than a build failure. Two signing paths
# feed the image -- Kbuild's MODULE_SIG_ALL for modules routed through
# modules_install, and edge-sign-kernel-module.inc for recipes that hand-install
# their .ko -- and neither proves the *image* is wholly signed. This does.
ROOTFS_POSTPROCESS_COMMAND += "edge_check_modules_signed;"

edge_check_modules_signed() {
    unsigned=""
    for ko in $(find ${IMAGE_ROOTFS}/lib/modules -name '*.ko' 2>/dev/null); do
        if ! tail -c 40 "$ko" | grep -qa "Module signature appended"; then
            unsigned="$unsigned $ko"
        fi
    done
    if [ -n "$unsigned" ]; then
        bbfatal "Unsigned kernel module(s) in the image; MODULE_SIG_FORCE would
 reject these at load time:$unsigned"
    fi
}

# Machine-specific image content, supplied by the board include. A distro
# class must not name a board; the board names what it needs.
CORE_IMAGE_EXTRA_INSTALL += " ${EDGE_MACHINE_EXTRA_INSTALL}"
