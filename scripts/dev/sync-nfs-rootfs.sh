#!/bin/bash
# Push the latest edge-image-dev rootfs + signed fitImage to the host's
# NFS+TFTP serving directories so the next `run netboot` on the board
# picks up the rebuild. Replaces the eject-reflash-reseat-boot loop with
# a ~5-second sync.
#
# Usage:
#   ./scripts/dev/sync-nfs-rootfs.sh
#   IMAGE=edge-image-base ./scripts/dev/sync-nfs-rootfs.sh
#   NFS_ROOT=/srv/nfs/edge-image-dev TFTP_DIR=/srv/tftp ./scripts/dev/sync-nfs-rootfs.sh
#
# Defaults match the runbook at docs/dev/netboot/README.md. Override via
# env vars to point at a different host layout.
#
# Requires:
#   - `make dev NETBOOT=1` (or `make base NETBOOT=1`) has run and the
#     deploy dir contains a fresh rootfs tarball + fitImage.
#   - The host's tftpd-hpa + nfs-kernel-server are configured per the
#     runbook (one-time setup; setup-tftp-nfs.sh helps).
#   - Run with sudo (or as root): the NFS root export needs root-owned
#     writes for permissions to survive into the rootfs.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-edge-image-dev}"
MACHINE="${MACHINE:-smarc-rzv2l}"
BOARD="${BOARD:-rzv2l}"
DEPLOY_DIR="${DEPLOY_DIR:-${REPO_ROOT}/build/${BOARD}/tmp/deploy/images/${MACHINE}}"
NFS_ROOT="${NFS_ROOT:-/srv/nfs/edge-image-dev}"
TFTP_DIR="${TFTP_DIR:-/srv/tftp/edge-fit-dev}"

die()  { echo "[sync-nfs-rootfs] ERROR: $*" >&2; exit 1; }
note() { echo "[sync-nfs-rootfs] $*"; }

[ -d "$DEPLOY_DIR" ] || die "deploy dir not found: $DEPLOY_DIR (run \`make dev NETBOOT=1\` first)"

# Newest tarball, by mtime — works with the timestamped wic.zst/tar.gz naming.
ROOTFS_TAR="$(ls -t "${DEPLOY_DIR}/${IMAGE}-${MACHINE}.rootfs"*.tar.gz 2>/dev/null | head -1 || true)"
[ -n "$ROOTFS_TAR" ] || die "no ${IMAGE}-${MACHINE}.rootfs-*.tar.gz under $DEPLOY_DIR"
FITIMAGE="${DEPLOY_DIR}/fitImage"
[ -f "$FITIMAGE" ] || die "fitImage missing under $DEPLOY_DIR"

# Privilege check up-front; NFS root export needs root for tar to preserve
# uid/gid/xattrs.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "must run as root (sudo). NFS root export needs root-owned writes for permissions to survive into the rootfs."
fi

note "rootfs:   $ROOTFS_TAR"
note "fitImage: $FITIMAGE"
note "→ NFS:    $NFS_ROOT"
note "→ TFTP:   $TFTP_DIR/fitImage"

# NFS root: wipe + repopulate. Atomic-ish — boards already booted from the
# old rootfs keep their open fds; new boots get the fresh copy. If a board
# is mid-boot during the sync, it may stumble — sync between iterations,
# not during one.
install -d -m 0755 "$NFS_ROOT"
note "wiping existing NFS root contents"
find "$NFS_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
note "extracting rootfs (numeric-owner + xattrs)"
# The export is readable as root by every admitted client: the OTA client key
# and the bundle decryption key are not extracted onto it unless KEEP_SECRETS=1
# (sudo KEEP_SECRETS=1 ..., or make netboot-sync KEEP_SECRETS=1).
SECRETS=(etc/ota/device.key etc/ota/bundle-decrypt.key)
EXCLUDES=()
if [ "${KEEP_SECRETS:-0}" != 1 ]; then
    for k in "${SECRETS[@]}"; do EXCLUDES+=("--exclude=$k"); done
fi
tar xpf "$ROOTFS_TAR" -C "$NFS_ROOT" \
    --numeric-owner \
    --xattrs \
    --xattrs-include='*' \
    "${EXCLUDES[@]}"

# Backstop for a tarball whose member names the excludes did not match.
# find -type f inside the export only: an /etc/ota symlink is not followed.
if [ "${KEEP_SECRETS:-0}" != 1 ]; then
    if [ -d "$NFS_ROOT/etc/ota" ] && [ ! -L "$NFS_ROOT/etc/ota" ] && [ ! -L "$NFS_ROOT/etc" ]; then
        find "$NFS_ROOT/etc/ota" -maxdepth 1 -type f \
            \( -name device.key -o -name bundle-decrypt.key \) -print -delete \
            | sed 's/^/[sync-nfs-rootfs] removed from the export: /'
    fi
    note "OTA private keys not exported (KEEP_SECRETS=1 keeps them)"
fi

# TFTP: replace the fitImage atomically (rename is atomic on the same FS).
install -d -m 0755 "$TFTP_DIR"
TMP_FIT="$(mktemp -p "$TFTP_DIR" .fitImage.XXXXXX)"
install -m 0644 "$FITIMAGE" "$TMP_FIT"
mv "$TMP_FIT" "$TFTP_DIR/fitImage"

# Re-export so mountd's authoritative-handle cache picks up any inode
# changes from the wipe-and-extract. Survives 'rpc.mountd not running'
# silently (warn only) — operator may not have started the service yet.
if command -v exportfs >/dev/null 2>&1; then
    exportfs -ra 2>/dev/null || note "exportfs -ra failed (server not running yet?) — start nfs-kernel-server and try again"
fi

note "done. On the board: \`run netboot\` at the U-Boot prompt."
