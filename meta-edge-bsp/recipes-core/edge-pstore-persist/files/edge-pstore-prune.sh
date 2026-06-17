#!/usr/bin/env bash
# Prune /data/crash/pstore: xz-compress old uncompressed records, then
# enforce a max file count and total size. Run by edge-pstore-prune.service
# after systemd-pstore.service archives the latest /sys/fs/pstore contents.
#
# Defaults (override via the service environment if needed):
#   EDGE_PSTORE_MAX_FILES  — keep at most N records (oldest pruned first)
#   EDGE_PSTORE_MAX_BYTES  — keep total dir size under N bytes (oldest first)
set -euo pipefail

PSTORE_DIR="/data/crash/pstore"
MAX_FILES="${EDGE_PSTORE_MAX_FILES:-20}"
MAX_BYTES="${EDGE_PSTORE_MAX_BYTES:-104857600}"   # 100 MiB

log()  { echo "[edge-pstore-prune] $*"; }
warn() { echo "[edge-pstore-prune] WARN: $*" >&2; }

[ -d "${PSTORE_DIR}" ] || exit 0

# Compress older plain-text records; keep newest 4 uncompressed for quick
# triage. Failures are logged but non-fatal — an uncompressed record is
# still useful, and prune_by_size enforces the hard upper bound anyway.
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ! xz -T0 -f "$f"; then
        warn "xz compression failed for $(basename "$f"); leaving uncompressed"
    fi
done < <(find "${PSTORE_DIR}" -maxdepth 1 -type f \
    ! -name "*.xz" \
    ! -name "*.gz" \
    ! -name ".keep" \
    -printf '%T@ %p\n' | sort -nr | awk 'NR>4 {print $2}')

prune_by_count() {
    local total
    total="$(find "${PSTORE_DIR}" -maxdepth 1 -type f ! -name ".keep" | wc -l)"
    [ "${total}" -le "${MAX_FILES}" ] && return 0
    while IFS= read -r f; do
        if ! rm -f "$f"; then
            warn "failed to remove $(basename "$f"); count-based prune may be incomplete"
        fi
    done < <(find "${PSTORE_DIR}" -maxdepth 1 -type f ! -name ".keep" -printf '%T@ %p\n' \
        | sort -n | head -n "$((total - MAX_FILES))" | awk '{print $2}')
}

prune_by_size() {
    local size oldest prev_size
    size="$(du -sb "${PSTORE_DIR}" | awk '{print $1}')"
    while [ "${size}" -gt "${MAX_BYTES}" ]; do
        oldest="$(find "${PSTORE_DIR}" -maxdepth 1 -type f ! -name ".keep" -printf '%T@ %p\n' | sort -n | head -n1 | awk '{print $2}')"
        [ -n "${oldest}" ] || break
        prev_size="${size}"
        if ! rm -f "${oldest}"; then
            warn "failed to remove ${oldest}; aborting size-based prune to avoid loop"
            return 1
        fi
        size="$(du -sb "${PSTORE_DIR}" | awk '{print $1}')"
        # Defensive: if size didn't drop, something is wrong (file in use,
        # fs error). Bail rather than spin.
        if [ "${size}" -ge "${prev_size}" ]; then
            warn "size did not decrease after removing ${oldest} (${prev_size}->${size}); aborting"
            return 1
        fi
    done
}

prune_by_count
prune_by_size

log "retention applied (max_files=${MAX_FILES}, max_bytes=${MAX_BYTES})"
