# Default users for every image tier that inherits edge-image-common.inc.
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

# Fail at parse time if the operator forgot to set the hash, set a
# malformed value, OR set an unescaped value that the shell will eat.
#
# Three guards (one is not enough — past incidents proved each layer):
#  1. presence: empty / unset → fatal
#  2. shell-escape: every `$` MUST be backslash-prefixed (`\$`).
#     extrausers.bbclass interpolates EXTRA_USERS_PARAMS into a shell
#     `var="…"` assignment; unescaped `$6$rounds=…$qO5…$Di…` has every
#     `$X` token expanded as a shell var ref and silently deleted. The
#     /etc/shadow entry parses but decodes to nothing. Catch this BEFORE
#     it ships.
#  3. format-shape: after the backslashes are conceptually stripped, the
#     value must match the sha512crypt grammar. The shape check can't
#     catch "valid format but wrong digest bytes" — that's still the
#     operator's discipline (`openssl passwd -6` + paste the output
#     unchanged), but every other class of corruption is caught here.
python () {
    import re
    h = d.getVar('EDGE_DEFAULT_PASSWORD_HASH')
    if not h:
        bb.fatal(
            "EDGE_DEFAULT_PASSWORD_HASH is unset.\n"
            "  Set it in kas/local.yml (operator-private; gitignored). See\n"
            "  kas/local.yml.example for the template. Generate a hash with:\n"
            "    openssl passwd -6 'your-password'\n"
            "  Building an image without a managed password hash would leave\n"
            "  default credentials in the artefact — refusing."
        )
    # Shell-escape check. Every `$` must be preceded by `\`.
    # Why: extrausers.bbclass's set_user_group function does
    #   user_group_settings="${EXTRA_USERS_PARAMS}"
    # then `echo $user_group_settings`. Bitbake substitutes the hash
    # verbatim into the shell source. Unescaped `$X` is then expanded
    # by the shell, eating salt/digest characters and silently shipping
    # a broken hash to /etc/shadow. The escape `\$` keeps the dollar
    # literal through both bitbake (which doesn't expand `$X`) and the
    # shell (which sees `\$` as a literal `$`).
    if re.search(r'(?<!\\)\$', h):
        bb.fatal(
            "EDGE_DEFAULT_PASSWORD_HASH contains an unescaped '$' character.\n"
            "  Got: %s\n"
            "  Every '$' in the hash MUST be written as '\\$' so the shell\n"
            "  doesn't expand it as a variable reference during image\n"
            "  assembly. Example of CORRECT form:\n"
            "    \\$6\\$rounds=656000\\$<salt>\\$<digest>\n"
            "  See edge-users.inc for the full explanation." % h
        )
    # sha512crypt shape (after conceptually stripping the escapes).
    stripped = h.replace('\\$', '$')
    if not re.match(r'^\$6\$(rounds=\d+\$)?[A-Za-z0-9./]{1,16}\$[A-Za-z0-9./]{86}$', stripped):
        bb.fatal(
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
}

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
    useradd -G wheel,systemd-journal,dialout,audio,video,input,tty,render,wayland \
            -m -s /bin/bash \
            -p '${EDGE_DEFAULT_PASSWORD_HASH}' devel; \
"
# Supplementary group choice for devel:
#   wheel            sudo escalation (paired with edge-sudoers)
#   systemd-journal  journalctl -f / read all messages without -q
#   dialout          /dev/tty[USB|S]* for nested-board debug + UART
#   audio, video, input
#                    ALSA + DRM + evdev for weston / multimedia work
#   tty              direct /dev/tty* access
#   render           DRM render nodes (drp-ai, mesa, opencl)
#   wayland          weston socket access (clients)
# All of these are created either by base-passwd (wheel/dialout/audio/
# video/input/tty) or by systemd-journald / weston-init recipes — both
# of which are in edge-image-base and edge-image-dev, so this -G list is
# safe for either image.

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
