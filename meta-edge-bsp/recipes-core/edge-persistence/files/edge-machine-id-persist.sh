#!/bin/sh
# Capture /etc/machine-id to /data on first boot; restore from /data on
# subsequent boots. Ordered before systemd-machine-id-commit so the value
# committed survives RAUC slot swaps.

set -e

PERSIST=/data/machine-id/id
LIVE=/etc/machine-id

log() { echo "[edge-machine-id-persist] $*"; }

mkdir -p /data/machine-id

if [ -s "${PERSIST}" ]; then
    if ! cmp -s "${PERSIST}" "${LIVE}" 2>/dev/null; then
        log "restoring machine-id from ${PERSIST}"
        # On the dm-verity root /etc is immutable and PID 1 has already
        # bind-mounted a transient id over /etc/machine-id; stack the
        # persisted copy on top. cp remains the path for a writable /etc
        # (legacy rw images).
        if cp "${PERSIST}" "${LIVE}" 2>/dev/null; then
            chmod 0444 "${LIVE}"
        else
            mount --bind "${PERSIST}" "${LIVE}"
        fi
    fi
elif [ -s "${LIVE}" ]; then
    log "capturing first-boot machine-id to ${PERSIST}"
    cp "${LIVE}" "${PERSIST}"
    chmod 0444 "${PERSIST}"
fi
