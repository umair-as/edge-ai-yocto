#!/usr/bin/env bash
# Grow /data to consume the rest of the storage device on first boot.
# One mechanism for both layouts: GPT (eMMC boot) uses systemd-repart for the
# partition resize + backup-header relocation; MBR (eSD boot) uses parted. The
# filesystem tail (e2fsck + resize2fs + tune2fs) is shared. No gptfdisk: the GPT
# backup header is relocated by systemd-repart, not sgdisk.

set -Eeuo pipefail

STAMP="/boot/.edge-data-grown"
LOG_TAG="edge-grow"

log_info() { printf '▶  [%s] %s\n'   "$LOG_TAG" "$*" >&2; }
log_ok()   { printf '✓  [%s] %s\n'   "$LOG_TAG" "$*" >&2; }
log_warn() { printf '⚠  [%s] %s\n'   "$LOG_TAG" "$*" >&2; }
log_err()  { printf '✗  [%s] %s\n'   "$LOG_TAG" "$*" >&2; }
log_skip() { printf '⏭  [%s] %s\n'   "$LOG_TAG" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

on_err() { die "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

resolve_data_part() {
    if [ -e /dev/disk/by-label/data ]; then
        readlink -f /dev/disk/by-label/data
        return 0
    fi
    # First-boot fallback: partition can exist but be unformatted/unlabeled.
    if [ -b /dev/mmcblk0p4 ]; then
        echo /dev/mmcblk0p4
        return 0
    fi
    lsblk -rno KNAME,LABEL | awk '$2=="data"{print "/dev/"$1; found=1} END{exit (found?0:1)}'
}

wait_for_data_part() {
    local i=0
    while [ "$i" -lt 40 ]; do
        if DATA_PART="$(resolve_data_part 2>/dev/null)"; then
            printf '%s\n' "$DATA_PART"
            return 0
        fi
        i=$((i + 1))
        sleep 0.25
    done
    return 1
}

already_done() {
    [ -f "$STAMP" ]
}

run_parted_resize() {
    local disk="$1" part_num="$2" err_file="$3"

    if parted -s "$disk" resizepart "$part_num" 100% 2>"$err_file"; then
        return 0
    fi
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    parted -s "$disk" resizepart "$part_num" 100% 2>"$err_file"
}

main() {
    if already_done; then
        log_skip "stamp present at $STAMP; nothing to do"
        return 0
    fi

    command -v parted    >/dev/null 2>&1 || die "parted not installed"
    command -v resize2fs >/dev/null 2>&1 || die "resize2fs not installed"
    command -v e2fsck    >/dev/null 2>&1 || die "e2fsck not installed"
    command -v tune2fs   >/dev/null 2>&1 || die "tune2fs not installed"
    command -v lsblk     >/dev/null 2>&1 || die "lsblk not installed"
    command -v partprobe >/dev/null 2>&1 || die "partprobe not installed"
    command -v udevadm   >/dev/null 2>&1 || die "udevadm not installed"

    DATA_PART="$(wait_for_data_part)" || die "could not resolve data partition"
    [ -b "$DATA_PART" ] || die "not a block device: $DATA_PART"

    base="$(basename "$DATA_PART")"
    case "$base" in
        mmcblk*p*[0-9]) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        nvme*n*p[0-9]*) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        *[0-9])         DISK="/dev/${base%[0-9]*}"; PART_NUM=${base##*[!0-9]} ;;
        *) die "cannot parse disk/partition from $base" ;;
    esac
    log_info "target partition: $DATA_PART (disk=$DISK part=$PART_NUM)"

    partprobe "$DISK" 2>/dev/null || true

    # Partition resize. GPT and MBR diverge only here.
    PTTYPE="$(lsblk -ndo PTTYPE "$DISK" 2>/dev/null || true)"
    if [ -z "$PTTYPE" ]; then
        PTTYPE="$(parted -s "$DISK" print 2>/dev/null | sed -n 's/^Partition Table: //p' | head -n1 || true)"
    fi
    if [ "$PTTYPE" = "gpt" ]; then
        # systemd-repart grows the /data partition (matched by type GUID in
        # /etc/repart.d/50-data.conf) and relocates the GPT backup header to the
        # true end of the device. Exit 76 (no root block device) / 77 (no GPT)
        # are benign on a layout it does not own.
        command -v systemd-repart >/dev/null 2>&1 || die "systemd-repart not installed (GPT media)"
        rc=0; systemd-repart --dry-run=no 1>&2 || rc=$?
        case "$rc" in 0|76|77) ;; *) die "systemd-repart failed (exit $rc)" ;; esac
        log_ok "systemd-repart grew GPT /data + relocated backup header"
    else
        RESIZE_ERR="$(mktemp)"
        if run_parted_resize "$DISK" "$PART_NUM" "$RESIZE_ERR"; then
            log_ok "resized MBR partition $PART_NUM to 100%"
        elif grep -qi "cannot be grown\|already at maximum size\|out of range\|in use\|busy" "$RESIZE_ERR" 2>/dev/null; then
            log_info "partition appears already at maximum size; continuing"
        else
            cat "$RESIZE_ERR" >&2 || true; rm -f "$RESIZE_ERR" || true
            die "parted resizepart failed"
        fi
        rm -f "$RESIZE_ERR" || true
    fi

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    FSTYPE="$(blkid -o value -s TYPE "$DATA_PART" 2>/dev/null || true)"
    if [ -z "$FSTYPE" ]; then
        log_warn "no filesystem on $DATA_PART; creating ext4 with label=data"
        mkfs.ext4 -F -L data "$DATA_PART" 1>&2
        FSTYPE="ext4"
    fi
    [ "$FSTYPE" = "ext4" ] || die "unsupported filesystem on $DATA_PART: $FSTYPE"

    log_info "growing filesystem on $DATA_PART"
    e2fsck -f -p "$DATA_PART" 1>&2 || true
    resize2fs "$DATA_PART" 1>&2
    log_ok "filesystem grown"

    # Reclaim the ext4 root-reserve. The 5% default keeps root logins possible
    # on a full /; on /data (written only via bind mounts) it is dead weight.
    if tune2fs -m 0 "$DATA_PART" 1>&2; then
        log_ok "reserved-blocks reset to 0% (reclaimed ~5% of /data)"
    else
        log_warn "tune2fs -m 0 failed (non-fatal); /data keeps default 5% reserve"
    fi

    touch "$STAMP"
    log_ok "growth complete; stamp written to $STAMP"
}

main "$@"
