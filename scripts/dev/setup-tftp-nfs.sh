#!/bin/bash
# One-time host bootstrap for the dev netboot workflow.
#
# Installs + configures:
#   tftpd-hpa            — TFTP server (root: /srv/tftp)
#   nfs-kernel-server    — NFS server (export: /srv/nfs/edge-image-dev)
#
# Idempotent: safe to re-run. Detects whether each step is already done
# and skips it. Reads sudo password once at the top, then runs the rest
# uninterrupted.
#
# Usage:
#   ./scripts/dev/setup-tftp-nfs.sh
#   SUBNET=192.168.20.0/24 ./scripts/dev/setup-tftp-nfs.sh
#   TFTP_DIR=/srv/tftp NFS_ROOT=/srv/nfs/edge-image-dev ./scripts/dev/setup-tftp-nfs.sh
#
# After running:
#   - Build a netboot-enabled image:   make dev NETBOOT=1
#   - Set serverip + nfs_export on the board (at the U-Boot prompt — see
#     docs/dev/netboot-setup.md)
#   - Push rootfs + fitImage:          make netboot-sync
#   - On the board:                    run netboot

set -Eeuo pipefail

# Defaults — override via env if your bench layout differs.
TFTP_DIR="${TFTP_DIR:-/srv/tftp}"
TFTP_SUBDIR="${TFTP_SUBDIR:-edge-fit-dev}"
NFS_ROOT="${NFS_ROOT:-/srv/nfs/edge-image-dev}"
SUBNET="${SUBNET:-192.168.0.0/24}"

# Detect the host's primary wired IP (default-route source) for the
# "host IP" hint at the end. Not used to configure anything — purely
# informational so the operator knows what to set as serverip on the
# board.
HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'match($0,/src ([0-9.]+)/,m){print m[1]; exit}' || true)"
HOST_IF="$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'match($0,/dev ([^ ]+)/,m){print m[1]; exit}' || true)"

note() { printf '[setup] %s\n' "$*"; }
die()  { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

# Privilege check: re-exec under sudo if not already root. Single
# password prompt, then the rest runs uninterrupted.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    exec sudo --preserve-env=TFTP_DIR,TFTP_SUBDIR,NFS_ROOT,SUBNET -- "$0" "$@"
fi

# -------- Step 1: TFTP --------
note "TFTP: install + config"

if ! command -v in.tftpd >/dev/null 2>&1; then
    note "installing tftpd-hpa"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y tftpd-hpa
else
    note "tftpd-hpa already installed"
fi

mkdir -p "$TFTP_DIR/$TFTP_SUBDIR"
chown -R tftp:tftp "$TFTP_DIR"
chmod 0755 "$TFTP_DIR" "$TFTP_DIR/$TFTP_SUBDIR"

# Confirm /etc/default/tftpd-hpa points at the expected directory. Don't
# overwrite a customized config; just warn.
if [ -f /etc/default/tftpd-hpa ]; then
    cfg_dir="$(. /etc/default/tftpd-hpa && echo "${TFTP_DIRECTORY:-}")"
    if [ "$cfg_dir" != "$TFTP_DIR" ]; then
        note "WARN: /etc/default/tftpd-hpa TFTP_DIRECTORY=$cfg_dir, expected $TFTP_DIR"
        note "      edit it manually or set TFTP_DIR= to match"
    fi
fi

# tftpd-hpa ships as a SysV init script on Debian/Ubuntu — `service`
# is the reliable start path. `systemctl enable` registers it under
# systemd-sysv but doesn't always start it.
service tftpd-hpa restart >/dev/null
systemctl enable tftpd-hpa.service >/dev/null 2>&1 || true
sleep 1

if ss -ulnp 2>/dev/null | grep -q ':69 '; then
    note "tftpd-hpa listening on :69/udp"
else
    die "tftpd-hpa did not bind :69/udp — check 'journalctl -u tftpd-hpa'"
fi

# -------- Step 2: NFS --------
note "NFS: install + config"

if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
    note "installing nfs-kernel-server"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server
else
    note "nfs-kernel-server already installed"
fi

mkdir -p "$NFS_ROOT"
chown root:root "$NFS_ROOT"
chmod 0755 "$NFS_ROOT"

# Idempotent /etc/exports edit. Match the FULL line including options
# so a re-run with different SUBNET adds a new entry rather than silently
# leaving a stale one. Operator can hand-prune for a single canonical entry.
# Intentional: NO fsid=root. fsid=root makes the export the NFSv4
# pseudo-root, which means v4 clients see it as `/` and the path
# `${NFS_ROOT}` passed in `nfsroot=…` hangs the kernel-mode v4 mount
# silently. Without fsid=root the export is reachable at its real path
# from both v3 and v4. The kernel-mode root-NFS client uses v3 by
# default (see the `vers=3` in rauc-uboot-env.dev-netboot's bootargs).
EXPORT_LINE="${NFS_ROOT}  ${SUBNET}(rw,sync,no_subtree_check,no_root_squash,no_acl)"
if grep -qxF "$EXPORT_LINE" /etc/exports 2>/dev/null; then
    note "/etc/exports already has the expected line — skipping"
else
    printf '\n# edge-ai-yocto dev NFS-root (%s)\n%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$EXPORT_LINE" >> /etc/exports
    note "appended export line: $EXPORT_LINE"
fi

exportfs -ra
systemctl enable --now nfs-kernel-server.service >/dev/null

if systemctl is-active --quiet nfs-kernel-server.service; then
    note "nfs-kernel-server active"
else
    die "nfs-kernel-server failed to start — check 'journalctl -u nfs-kernel-server'"
fi

# -------- Smoke tests --------
note ""
note "=== smoke tests ==="
note ""

note "exportfs -v:"
exportfs -v 2>&1 | sed 's/^/  /'

note ""
note "showmount -e localhost:"
showmount -e localhost 2>&1 | sed 's/^/  /'

note ""
note "listening (69 tftp, 111 rpcbind, 2049 nfs, 20048 mountd):"
ss -tulnp 2>/dev/null | awk '/:(69|111|2049|20048)\>/ {print "  "$0}' || true

# -------- Final summary --------
note ""
note "==================================================================="
note "DONE. Host is ready for dev netboot."
note ""
note "  Host IP for the board:  ${HOST_IP:-<unknown>}${HOST_IF:+ ($HOST_IF)}"
note "  NFS root:               $NFS_ROOT"
note "  TFTP root:              $TFTP_DIR/$TFTP_SUBDIR"
note ""
note "Next steps:"
note "  1. make dev NETBOOT=1                 # build the netboot-enabled image"
note "  2. flash the SD card ONCE             # only first time; never again"
note "  3. on board at U-Boot prompt:"
note "       setenv serverip ${HOST_IP:-<your-host-ip>}"
note "       setenv nfs_export $NFS_ROOT"
note "       saveenv"
note "  4. make netboot-sync                  # push rootfs+fitImage to host"
note "  5. on board:  reset; (stop autoboot with 'edge'); run netboot"
note ""
note "See docs/dev/netboot-setup.md for the full runbook."
note "==================================================================="
