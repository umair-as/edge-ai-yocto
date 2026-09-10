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

# Container userspace is NOT installed here. It is an unconditional RDEPENDS
# of packagegroup-edge-base (installed above), so anything pulling the base
# packagegroup gets the container runtime whether or not it came through this
# class. One source, no second place to forget. See ADR-0012.

# EDGE_DEFAULT_PASSWORD_HASH validation. Three guards, one is not enough --
# past incidents proved each layer:
#  1. presence: empty / unset.
#  2. shell-escape: every `$` MUST be backslash-prefixed (`\$`).
#     extrausers.bbclass interpolates EXTRA_USERS_PARAMS into a shell
#     `var="…"` assignment; unescaped `$6$rounds=…$qO5…$Di…` has every `$X`
#     token expanded as a shell var ref and silently deleted. The /etc/shadow
#     entry parses but decodes to nothing.
#  3. format-shape: after the backslashes are conceptually stripped, the value
#     must match the sha512crypt grammar. This cannot catch "valid format but
#     wrong digest bytes" -- that stays the operator's discipline -- but every
#     other class of corruption is caught.
#
# Enforced as a do_rootfs prefunc rather than at parse. The guard's purpose is
# that a default-credential image must not leave CI, and a prefunc delivers
# exactly that: no rootfs is assembled without a managed hash. Enforcing it at
# parse instead put a distro-scope bb.fatal in front of every recipe in the
# tree, so the repo could not be parsed at all without an operator's private
# kas/local.yml. The parse-time hook below warns so a missing hash is still
# reported immediately, not hours later at do_rootfs.
def edge_password_hash_problem(d):
    import re
    h = d.getVar('EDGE_DEFAULT_PASSWORD_HASH')
    if not h:
        return (
            "EDGE_DEFAULT_PASSWORD_HASH is unset.\n"
            "  Set it in kas/local.yml (operator-private; gitignored). See\n"
            "  kas/local.yml.example for the template. Generate a hash with:\n"
            "    openssl passwd -6 'your-password'\n"
            "  Building an image without a managed password hash would leave\n"
            "  default credentials in the artefact — refusing."
        )
    if re.search(r'(?<!\\)\$', h):
        return (
            "EDGE_DEFAULT_PASSWORD_HASH contains an unescaped '$' character.\n"
            "  Got: %s\n"
            "  Every '$' in the hash MUST be written as '\\$' so the shell\n"
            "  doesn't expand it as a variable reference during image\n"
            "  assembly. Example of CORRECT form:\n"
            "    \\$6\\$rounds=656000\\$<salt>\\$<digest>\n"
            "  See edge-users.inc for the full explanation." % h
        )
    stripped = h.replace('\\$', '$')
    if not re.match(r'^\$6\$(rounds=\d+\$)?[A-Za-z0-9./]{1,16}\$[A-Za-z0-9./]{86}$', stripped):
        return (
            "EDGE_DEFAULT_PASSWORD_HASH is not a valid sha512crypt digest.\n"
            "  Expected: \\$6\\$[rounds=N\\$]<salt 1-16>\\$<digest 86>\n"
            "  Got:      %s\n"
            "  Common mistakes:\n"
            "    - hand-edited digest bytes from a placeholder (superficially\n"
            "      looks valid, doesn't decode to any password — login fails\n"
            "      silently after boot)\n"
            "    - truncated digest segment (must be exactly 86 chars)\n"
            "    - characters outside the crypt(3) alphabet [A-Za-z0-9./]\n"
            "  Regenerate with:\n"
            "    openssl passwd -6 'your-password'\n"
            "  and paste the output with every '$' replaced by '\\$'." % h
        )
    return None

python edge_check_password_hash() {
    problem = edge_password_hash_problem(d)
    if problem:
        bb.fatal(problem)
}
do_rootfs[prefuncs] += "edge_check_password_hash"
edge_check_password_hash[vardeps] += "EDGE_DEFAULT_PASSWORD_HASH"

# The board check exists because a missing conf/machine/include/edge-board-
# ${MACHINE}.inc is otherwise completely silent (bitbake logs a failed soft
# include at debug2), and the values it carries -- slot devices written into
# the signed verity table, FIP offsets, FIT load addresses -- fail as a
# green build producing an unbootable image rather than as an error.
#
# Board contract + accelerator selection, both fail-closed.
#
# The accelerator check refuses a machine/accelerator pair the board does not
# declare. Building without the accelerator is deliberately NOT the fallback:
# an image that silently lacks its accelerator is the failure this prevents.
python () {
    # Reported here so a missing or malformed hash is visible at parse rather
    # than only when do_rootfs is reached. Warn, not fatal: this class is
    # parsed for the image recipes during a whole-tree `bitbake -p`, and a
    # fatal here would make the repo unparseable without a private local.yml
    # again. edge_check_password_hash is the enforcing copy.
    problem = edge_password_hash_problem(d)
    if problem:
        bb.warn("%s\n  This is fatal at do_rootfs; the image will not build."
                % problem)

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

    # Boot-chain family. Only one is implemented; a board from another
    # family (UEFI/extlinux, Jetson-class) must fail here naming the gap
    # rather than build an image whose verity table is anchored to nothing.
    EDGE_BOOT_CHAINS_IMPLEMENTED = ("uboot-fit",)
    chain = (d.getVar('EDGE_BOOT_CHAIN') or '').strip()
    if not chain:
        bb.fatal(
            "EDGE_BOOT_CHAIN is unset for MACHINE = '%s'.\n"
            "  Set it in conf/machine/include/edge-board-%s.inc.\n"
            "  Implemented: %s"
            % (d.getVar('MACHINE'), d.getVar('MACHINE'),
               ' '.join(EDGE_BOOT_CHAINS_IMPLEMENTED)))
    if chain not in EDGE_BOOT_CHAINS_IMPLEMENTED:
        bb.fatal(
            "EDGE_BOOT_CHAIN = '%s' is not implemented (MACHINE = '%s').\n"
            "  Implemented: %s\n"
            "  The boot, signing and OTA-env recipes assume the U-Boot/FIT\n"
            "  family; another family needs its own trust anchor and\n"
            "  boot-count store, not a fallback."
            % (chain, d.getVar('MACHINE'),
               ' '.join(EDGE_BOOT_CHAINS_IMPLEMENTED)))

    accel = (d.getVar('EDGE_ACCEL') or 'none').strip()
    if accel == 'none':
        # An accelerator-less image is not a supported product configuration:
        # every board this distro targets carries an accelerator (DRP-AI in
        # the RZ/V2L SoC, DX-M1 on PCIe for the RPi5), and an edge-ai image
        # that cannot run inference has no purpose. This used to return
        # quietly, which made "no accelerator" the silent default whenever a
        # composition forgot the fragment.
        if d.getVar('EDGE_ALLOW_NO_ACCEL') == '1':
            bb.warn(
                "Building MACHINE = '%s' with NO accelerator because "
                "EDGE_ALLOW_NO_ACCEL = '1'.\n"
                "  This is a bring-up composition only -- board boot before "
                "its accelerator is integrated.\n"
                "  The resulting image cannot run inference and must not be "
                "treated as a product image."
                % d.getVar('MACHINE'))
            return
        bb.fatal(
            "No accelerator composed for MACHINE = '%s'.\n"
            "  EDGE_ACCEL is unset. The machine fragment composes its\n"
            "  accelerator (kas/machines/<board>.yml -> kas/accel/<name>.yml);\n"
            "  this machine declares EDGE_ACCEL_SUPPORTED = '%s'.\n"
            "  An image without its accelerator is refused rather than built:\n"
            "  inference is the point of the platform, not a feature of it.\n"
            "  For board bring-up before the accelerator is integrated, set\n"
            "  EDGE_ALLOW_NO_ACCEL = \"1\" explicitly and accept the warning."
            % (d.getVar('MACHINE'), d.getVar('EDGE_ACCEL_SUPPORTED') or ''))
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
# here. Empty only in the EDGE_ALLOW_NO_ACCEL bring-up case, which the gate
# above has already warned about; every other path has a real accelerator.
CORE_IMAGE_EXTRA_INSTALL += "${@'' if (d.getVar('EDGE_ACCEL') or 'none') == 'none' else ' packagegroup-edge-accel-' + d.getVar('EDGE_ACCEL')}"

# Every kernel module in the image must carry a signature trailer. The image
# is built with MODULE_SIG_FORCE, so an unsigned .ko is a module that silently
# fails to load on the target rather than a build failure. Two signing paths
# feed the image -- Kbuild's MODULE_SIG_ALL for modules routed through
# modules_install, and edge-sign-kernel-module.inc for recipes that hand-install
# their .ko -- and neither proves the *image* is wholly signed. This does.
#
# Scope: this establishes that a signature trailer is PRESENT on every module.
# It does not verify the signature cryptographically and does not prove the
# target's keyring trusts it; the trailer is appended text, and a module signed
# by the wrong key carries one too. Key trust is established at kernel build
# time via the module signing key, not here.
ROOTFS_POSTPROCESS_COMMAND += "edge_check_modules_signed;"

edge_check_modules_signed() {
    # No /lib/modules at all means no kernel packages landed. Note it and move
    # on -- there is nothing to verify. This is NOT the monolithic-kernel case:
    # kernel-base ships modules.order and modules.builtin under
    # /lib/modules/${KERNEL_VERSION} even when no module is built
    # (kernel.bbclass FILES:${KERNEL_PACKAGE_NAME}-base), so a module-free image
    # reaches the empty check below and fails there. That is intended: this
    # platform builds with MODULE_SIG_FORCE and expects modules, so "no modules"
    # is a composition error, not a valid image.
    if [ ! -d ${IMAGE_ROOTFS}/lib/modules ]; then
        bbnote "No /lib/modules in the image; no kernel packages to verify."
        return
    fi

    # No $(( )) arithmetic anywhere in this function: bitbake parses shell
    # functions with pysh, which raises NotImplementedError on arithmetic
    # expansion. Collect the list and test it for emptiness instead of counting.
    kos=$(find ${IMAGE_ROOTFS}/lib/modules \
               -name '*.ko' -o -name '*.ko.gz' \
               -o -name '*.ko.xz' -o -name '*.ko.zst' 2>/dev/null)

    # /lib/modules exists but held no modules: the loop below would inspect
    # nothing and report success. A gate that passes because it found no work is
    # indistinguishable from one that passed on merit.
    if [ -z "$kos" ]; then
        bbfatal "Module-signature check found no modules under /lib/modules, which exists. Either the modules are packaged under a name this check does not match, or kernel-modules did not land in the image."
    fi

    unsigned=""
    for ko in $kos; do
        case "$ko" in
            *.ko.gz)  dec="gzip -dc" ;;
            *.ko.xz)  dec="xz -dc"   ;;
            *.ko.zst) dec="zstd -dc" ;;
            *)        dec="cat"      ;;
        esac
        if ! $dec "$ko" | tail -c 40 | grep -qa "Module signature appended"; then
            unsigned="$unsigned $ko"
        fi
    done

    if [ -n "$unsigned" ]; then
        bbfatal "Unsigned kernel modules in the image; MODULE_SIG_FORCE would reject these at load time:$unsigned"
    fi
}


# Machine-specific image content, supplied by the board include. A distro
# class must not name a board; the board names what it needs.
CORE_IMAGE_EXTRA_INSTALL += " ${EDGE_MACHINE_EXTRA_INSTALL}"
