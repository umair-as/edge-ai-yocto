#!/bin/sh
# Generate-or-restore sshd host keys with /data as the source of truth.
# Ordered before sshdgenkeys: on first boot of a fresh /data this generates the
# keys directly into /data (then installs them live), so /data holds them
# immediately and sshdgenkeys finds an existing set and no-ops. On later boots
# and after a slot swap the keys are restored from /data, so the host
# fingerprint stays stable across OTA updates.
#
# The live location is /run tmpfs, not /etc/ssh: the dm-verity rootfs is
# immutable. sshd_hardening.conf points HostKey at LIVE_DIR; sshdgenkeys is
# the /data-broken fallback generating into the same LIVE_DIR.

set -e

PERSIST_DIR=/data/ssh
LIVE_DIR=/run/edge-sshd-keys
# Legacy rw-rootfs images kept live keys here; still readable on a verity
# root. Capture-only source — never written.
LEGACY_DIR=/etc/ssh

log() { echo "[edge-ssh-host-keys-persist] $*"; }

mkdir -p "${PERSIST_DIR}" "${LIVE_DIR}"
chmod 0700 "${PERSIST_DIR}" "${LIVE_DIR}"

# Only ed25519 is managed — the edge sshd policy (sshd_hardening.conf) ships an
# ed25519-only HostKey. ed25519 generation is instant (no RSA keygen cost).
for kt in ed25519; do
    priv="ssh_host_${kt}_key"
    pub="${priv}.pub"
    p_priv="${PERSIST_DIR}/${priv}"
    p_pub="${PERSIST_DIR}/${pub}"
    l_priv="${LIVE_DIR}/${priv}"
    l_pub="${LIVE_DIR}/${pub}"

    # 0. Repair a half-written pair before anything else. A private key with a
    #    missing or empty .pub is recoverable — the public half is derivable —
    #    but the generate branch below would call ssh-keygen against a private
    #    key that already exists. That prompts "Overwrite (y/n)?", reads EOF
    #    from the unit's /dev/null stdin, and exits 1; set -e then fails the
    #    unit, sshdgenkeys generates a fresh key, and the host fingerprint
    #    changes — the exact outcome this script exists to prevent. The state
    #    is not self-healing: every later boot lands in it again. Reachable by
    #    power loss between the two installs in step 1, on flash-backed /data.
    if [ -s "${p_priv}" ] && [ ! -s "${p_pub}" ]; then
        log "deriving missing ${kt} public key from ${p_priv}"
        if ! ssh-keygen -y -f "${p_priv}" > "${p_pub}.tmp" 2>/dev/null; then
            rm -f "${p_pub}.tmp"
            log "ERROR: cannot derive public key from ${p_priv}"
            exit 1
        fi
        chmod 0644 "${p_pub}.tmp"
        mv -f "${p_pub}.tmp" "${p_pub}"
    fi

    # 1. Ensure /data holds the key (capture a legacy on-rootfs key from a
    #    pre-verity image, else generate straight into /data on a fresh
    #    first boot).
    if [ ! -s "${p_priv}" ] || [ ! -s "${p_pub}" ]; then
        if [ -s "${LEGACY_DIR}/${priv}" ] && [ -s "${LEGACY_DIR}/${pub}" ]; then
            log "capturing legacy ${kt} host key to ${PERSIST_DIR}"
            install -m 0600 "${LEGACY_DIR}/${priv}" "${p_priv}"
            install -m 0644 "${LEGACY_DIR}/${pub}"  "${p_pub}"
        else
            log "generating ${kt} host key in ${PERSIST_DIR}"
            ssh-keygen -q -t "${kt}" -N "" -C "" -f "${p_priv}"
        fi
    fi

    # 2. Make the live set match /data (no-op when already identical).
    if ! cmp -s "${p_priv}" "${l_priv}" 2>/dev/null; then
        log "installing ${kt} host key into ${LIVE_DIR}"
        install -m 0600 "${p_priv}" "${l_priv}"
        install -m 0644 "${p_pub}"  "${l_pub}"
    fi
done
