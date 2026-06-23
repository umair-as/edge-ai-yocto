#!/bin/sh
# Generate-or-restore sshd host keys with /data as the source of truth.
# Ordered before sshdgenkeys: on first boot of a fresh /data this generates the
# keys directly into /data (then installs them live), so /data holds them
# immediately and sshdgenkeys finds an existing set and no-ops. On later boots
# and after a slot swap the keys are restored from /data, so the host
# fingerprint stays stable across OTA updates.

set -e

PERSIST_DIR=/data/ssh
LIVE_DIR=/etc/ssh

log() { echo "[edge-ssh-host-keys-persist] $*"; }

mkdir -p "${PERSIST_DIR}"
chmod 0700 "${PERSIST_DIR}"

# Only ed25519 is managed — the edge sshd policy (sshd_hardening.conf) ships an
# ed25519-only HostKey. ed25519 generation is instant (no RSA keygen cost).
for kt in ed25519; do
    priv="ssh_host_${kt}_key"
    pub="${priv}.pub"
    p_priv="${PERSIST_DIR}/${priv}"
    p_pub="${PERSIST_DIR}/${pub}"
    l_priv="${LIVE_DIR}/${priv}"
    l_pub="${LIVE_DIR}/${pub}"

    # 1. Ensure /data holds the key (capture a pre-existing live key, else
    #    generate straight into /data on a fresh first boot).
    if [ ! -s "${p_priv}" ] || [ ! -s "${p_pub}" ]; then
        if [ -s "${l_priv}" ] && [ -s "${l_pub}" ]; then
            log "capturing ${kt} host key to ${PERSIST_DIR}"
            install -m 0600 "${l_priv}" "${p_priv}"
            install -m 0644 "${l_pub}"  "${p_pub}"
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
