#!/bin/sh
# Capture sshd host keys to /data after first generation; restore from
# /data on subsequent boots. Ordered before sshdgenkeys so a restored key
# set causes sshdgenkeys to see existing keys and no-op.

set -e

PERSIST_DIR=/data/ssh
LIVE_DIR=/etc/ssh

log() { echo "[edge-ssh-host-keys-persist] $*"; }

mkdir -p "${PERSIST_DIR}"
chmod 0700 "${PERSIST_DIR}"

for kt in ed25519 rsa ecdsa; do
    priv="ssh_host_${kt}_key"
    pub="${priv}.pub"
    persist_priv="${PERSIST_DIR}/${priv}"
    persist_pub="${PERSIST_DIR}/${pub}"
    live_priv="${LIVE_DIR}/${priv}"
    live_pub="${LIVE_DIR}/${pub}"

    if [ -s "${persist_priv}" ] && [ -s "${persist_pub}" ]; then
        if ! cmp -s "${persist_priv}" "${live_priv}" 2>/dev/null; then
            log "restoring ${kt} host key"
            install -m 0600 -o root -g root "${persist_priv}" "${live_priv}"
            install -m 0644 -o root -g root "${persist_pub}"  "${live_pub}"
        fi
    elif [ -s "${live_priv}" ] && [ -s "${live_pub}" ]; then
        log "capturing ${kt} host key"
        install -m 0600 -o root -g root "${live_priv}" "${persist_priv}"
        install -m 0644 -o root -g root "${live_pub}"  "${persist_pub}"
    fi
done
