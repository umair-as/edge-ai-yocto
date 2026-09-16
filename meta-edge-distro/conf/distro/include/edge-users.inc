# Default users for every image tier that inherits edge-image.bbclass.
#
# Two users:
#   root  (UID 0)  — shell login allowed; SSH login DENIED in sshd config.
#                    Same password hash as devel. Physical-serial recovery
#                    only.
#   devel (UID 1000, primary GID 1000, supplementary "wheel") — interactive
#                    SSH user. wheel grants sudo (password required —
#                    no NOPASSWD), per meta-edge-bsp/recipes-core/users/edge-sudoers/.
#
# Password hash + SSH key are supplied by the operator via kas/local.yml
# (gitignored) — see kas/local.yml.example for the documented stub. The
# build fails noisily if EDGE_DEFAULT_PASSWORD_HASH is unset, by design —
# a default-credential image must not leave CI.
#
# To generate a hash:
#   openssl passwd -6 'your-password'         # → $6$...
# or
#   mkpasswd --method=sha-512 'your-password' # → $6$...

# The three EDGE_DEFAULT_PASSWORD_HASH guards (presence, shell-escaping,
# sha512crypt shape) are enforced in edge-image.bbclass: distro scope would
# run them for every recipe and make `bitbake -p` fail without a hash.

# extrausers.bbclass runs commands inside the rootfs at image build time
# to modify /etc/passwd, /etc/shadow, /etc/group. The wrynose-recommended
# way to set passwords / create users at image-build (not recipe-build).
# Inherited globally so every edge-image-* tier picks it up without each
# needing its own `inherit extrausers`.
INHERIT += "extrausers"

# Image-level user provisioning via extrausers, with UIDs/GIDs governed
# by the same useradd-staticids tables (files/passwd, files/group)
# that pin recipe-level system accounts — so devel's UID lives in
# exactly one place. Don't pass -u / -g here; staticids injects them
# from the table at parse time. wheel exists at GID 80 (base-passwd).
#
# Order matters: usermod -p on root MUST run before useradd devel (which
# also uses -p) so a partial failure leaves a determinable state. The
# groupadd before useradd creates the devel primary group; staticids
# fills in --gid 1000.
EXTRA_USERS_PARAMS = " \
    usermod -p '${EDGE_DEFAULT_PASSWORD_HASH}' root; \
    groupadd devel; \
    useradd -G wheel,systemd-journal,dialout,audio,video,input,tty,render${@',wayland' if d.getVar('EDGE_ENABLE_DISPLAY') == '1' else ''} \
            -m -s /bin/bash \
            -p '${EDGE_DEFAULT_PASSWORD_HASH}' devel; \
"

# Accelerator principal group membership. packagegroup-edge-containers
# creates the principal (edge-ctr), the accelerator stack creates the device
# groups; this adds
# the memberships that let it pass the accelerator's device nodes into a
# rootless container (keep-groups).
#
# Added at image assembly, not in the recipe useradd: the groups are created
# by other recipes and a recipe-level --groups races their creation.
#
# EDGE_ACCEL_SUPPLEMENTARY_GROUPS is supplied by the accelerator fragment and
# empty when none is selected. Entries are "group:user".
# Format is validated in edge-image.bbclass; a malformed entry is a parse
# error there rather than a silently skipped membership here.
EXTRA_USERS_PARAMS:append = "${@''.join(' usermod -aG %s %s;' % (e.split(':', 1)[0], e.split(':', 1)[1]) for e in (d.getVar('EDGE_ACCEL_SUPPLEMENTARY_GROUPS') or '').split() if ':' in e)}"

# Board-declared supplementary groups for devel (EDGE_BOARD_DEVEL_GROUPS,
# set in conf/machine/include/edge-board-<MACHINE>.inc). The groups are
# created by the board's own recipes (edge-io-udev: gpio), so they exist
# only where the board installs them; an entry for a group the image lacks
# fails do_rootfs, as with tee below.
EDGE_BOARD_DEVEL_GROUPS ??= ""
EXTRA_USERS_PARAMS:append = "${@''.join(' usermod -aG %s devel;' % g for g in (d.getVar('EDGE_BOARD_DEVEL_GROUPS') or '').split())}"

# optee-client creates the tee group owning /dev/tee0 (0660, no uaccess ACL);
# devel joins it to open a TEE context without sudo. Machine-scoped append, not
# a member of the universal -G list above: the tee group is absent on non-rzv2l
# machines, where -G tee would fail assembly. EDGE_ENABLE_OPTEE keys it for the
# same reason — with the packagegroup dropped, the group is absent on this board
# too, and usermod against a missing group fails the rootfs task.
EXTRA_USERS_PARAMS:append = "${@bb.utils.contains('EDGE_ENABLE_OPTEE', '1', ' usermod -aG tee devel;', '', d) if 'packagegroup-edge-optee' in (d.getVar('EDGE_MACHINE_EXTRA_INSTALL') or '') else ''}"
# Supplementary group choice for devel:
#   wheel            sudo escalation (paired with edge-sudoers)
#   systemd-journal  journalctl -f / read all messages without -q
#   dialout          /dev/tty[USB|S]* for nested-board debug + UART
#   audio, video, input
#                    ALSA + DRM + evdev for weston / multimedia work
#   tty              direct /dev/tty* access
#   render           DRM render nodes (drp-ai, mesa, opencl)
#   wayland          weston socket access (clients); only when the display
#                    stack is on -- weston-init creates the group, and a
#                    headless image (EDGE_ENABLE_DISPLAY = "0") has no such
#                    group, where naming it fails useradd at do_rootfs.
# The rest are created by base-passwd (wheel/dialout/audio/video/input/tty),
# systemd-journald, or udev (render), all present in every tier.

# Bake an operator-provided SSH public key into /home/devel/.ssh/authorized_keys.
# EDGE_DEVEL_SSH_PUBKEY_FILE points at a host-side .pub file (path is
# interpreted at image build time). If unset, the build still succeeds —
# the user lands on a password-only SSH posture and can ssh-copy-id after
# first login. With CRA hardening on, the gentler path is: set it.
EDGE_DEVEL_SSH_PUBKEY_FILE ?= ""

ROOTFS_POSTPROCESS_COMMAND:append = "${@' edge_devel_authorized_keys;' if d.getVar('EDGE_DEVEL_SSH_PUBKEY_FILE') else ''}"

edge_devel_authorized_keys() {
    if [ ! -f "${EDGE_DEVEL_SSH_PUBKEY_FILE}" ]; then
        bbfatal "EDGE_DEVEL_SSH_PUBKEY_FILE=${EDGE_DEVEL_SSH_PUBKEY_FILE} does not exist."
    fi
    install -d -m 0700 -o 1000 -g 1000 ${IMAGE_ROOTFS}/home/devel/.ssh
    install -m 0600 -o 1000 -g 1000 "${EDGE_DEVEL_SSH_PUBKEY_FILE}" \
        ${IMAGE_ROOTFS}/home/devel/.ssh/authorized_keys
}

# Subordinate uid/gid ranges for rootless podman (devel, and edge-ctr when the
# container principal is present). Non-overlapping, clear of system/login uids:
# devel 100000-165535, edge-ctr 200000-265535.
#
# Must run in ROOTFS_POSTUNINSTALL_COMMAND, not a pkg_postinst or
# ROOTFS_POSTPROCESS_COMMAND: /etc/sub{u,g}id are owned by the shadow package,
# and shadow is in ROOTFS_RO_UNNEEDED (image.bbclass), so a read-only-rootfs
# image erases it in _uninstall_unneeded() — after every postinst and after
# ROOTFS_POSTPROCESS_COMMAND. That erase deletes shadow's files, taking any
# appended ranges with them. ROOTFS_POSTUNINSTALL_COMMAND runs after the erase
# (rootfs.py) and before the verity/SELinux seal, so ranges written here reach
# the sealed rootfs. A first-boot fixup is impossible: the verity root is
# read-only.
ROOTFS_POSTUNINSTALL_COMMAND += "edge_write_subid_ranges;"

edge_write_subid_ranges() {
    for f in subuid subgid; do
        target=${IMAGE_ROOTFS}${sysconfdir}/$f
        grep -q '^devel:100000:' "$target" 2>/dev/null || \
            echo 'devel:100000:65536' >> "$target"
        if grep -q '^edge-ctr:' ${IMAGE_ROOTFS}${sysconfdir}/passwd 2>/dev/null; then
            grep -q '^edge-ctr:200000:' "$target" 2>/dev/null || \
                echo 'edge-ctr:200000:65536' >> "$target"
        fi
        chmod 0644 "$target"
    done
}
