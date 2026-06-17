#!/bin/sh
# Copy rootfs content into empty /data subdirs before the bind mounts
# activate, so /home/devel, container base layout, and NetworkManager
# defaults are not shadowed by an empty bind on first boot. Idempotent:
# the marker prevents re-seeding on subsequent boots and after RAUC slot
# swaps (the per-slot rootfs state is captured once, on the slot that
# first sees an unseeded /data).

set -e

SEED_MARKER=/data/.edge-seeded

if [ -f "${SEED_MARKER}" ]; then
    exit 0
fi

log() { echo "[edge-data-seed] $*"; }

seed_dir() {
    src="$1"; dst="$2"
    if [ ! -d "${src}" ]; then return 0; fi
    mkdir -p "${dst}"
    if [ -n "$(ls -A "${dst}" 2>/dev/null)" ]; then return 0; fi
    log "${src} -> ${dst}"
    cp -a "${src}/." "${dst}/"
}

seed_dir /home                   /data/home
seed_dir /var/lib/containers     /data/containers
seed_dir /var/lib/NetworkManager /data/nm
seed_dir /var/lib/systemd        /data/systemd

touch "${SEED_MARKER}"
log "seed complete"
