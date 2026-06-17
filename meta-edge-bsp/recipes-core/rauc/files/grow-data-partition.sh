#!/usr/bin/env bash
# Grow /data partition to consume remaining card space with robust logging.
# Handles RZ/V2L MBR layout, GPT backup-header relocation (if present), and
# first-boot fallbacks where /data may exist but not yet be formatted/labeled.

set -Eeuo pipefail

STAMP="/boot/.rauc-grow-done"
LOG_TAG="rauc-grow"

log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

on_err() { die "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

resolve_data_part() {
    if [ -e /dev/disk/by-label/data ]; then
        readlink -f /dev/disk/by-label/data
        return 0
    fi
    # RZ/V2L first-boot fallback: partition can exist but be unformatted/unlabeled.
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
    local disk="$1"
    local part_num="$2"
    local err_file="$3"

    if parted -s "$disk" resizepart "$part_num" 100% 2>"$err_file"; then
        return 0
    fi

    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    if parted -s "$disk" resizepart "$part_num" 100% 2>"$err_file"; then
        return 0
    fi

    return 1
}

main() {
    if already_done; then
        log "stamp present; nothing to do"
        return 0
    fi

    command -v parted >/dev/null 2>&1 || die "parted not installed"
    command -v resize2fs >/dev/null 2>&1 || die "resize2fs not installed"
    command -v e2fsck >/dev/null 2>&1 || die "e2fsck not installed"
    command -v lsblk >/dev/null 2>&1 || die "lsblk not installed"
    command -v partprobe >/dev/null 2>&1 || die "partprobe not installed"
    command -v udevadm >/dev/null 2>&1 || die "udevadm not installed"

    DATA_PART="$(wait_for_data_part)" || die "could not resolve data partition"
    [ -b "$DATA_PART" ] || die "not a block device: $DATA_PART"

    base="$(basename "$DATA_PART")"
    case "$base" in
        mmcblk*p*[0-9]) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        nvme*n*p[0-9]*) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        *[0-9])         DISK="/dev/${base%[0-9]*}"; PART_NUM=${base##*[!0-9]} ;;
        *) die "cannot parse disk/partition from $base" ;;
    esac

    log "target partition: $DATA_PART (disk=$DISK part=$PART_NUM)"

    partprobe "$DISK" 2>/dev/null || true

    # GPT backup-header relocation: required after a resizepart on GPT
    # media so the secondary header sits at the new end-of-disk. Skipped
    # for MBR media (RZ/V2L SD boot uses DOS/MBR).
    PTTYPE="$(lsblk -ndo PTTYPE "$DISK" 2>/dev/null || true)"
    if [[ -z "$PTTYPE" ]]; then
        PTTYPE="$(parted -s "$DISK" print 2>/dev/null | sed -n 's/^Partition Table: //p' | head -n1 || true)"
    fi
    if [[ "$PTTYPE" == "gpt" ]]; then
        command -v sgdisk >/dev/null 2>&1 || die "sgdisk required for GPT media but not installed"
        sgdisk -e "$DISK" >/dev/null 2>&1 || die "failed to relocate GPT backup header on $DISK"
        partprobe "$DISK" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    else
        log "partition table '${PTTYPE:-unknown}' is not GPT; skipping sgdisk -e"
    fi

    RESIZE_ERR="$(mktemp)"
    if run_parted_resize "$DISK" "$PART_NUM" "$RESIZE_ERR"; then
        log "resized partition $PART_NUM to 100%"
    else
        if grep -qi "cannot be grown\|already at maximum size\|out of range\|in use\|busy" "$RESIZE_ERR" 2>/dev/null; then
            log "partition appears already at maximum size; continuing"
        else
            cat "$RESIZE_ERR" >&2 || true
            rm -f "$RESIZE_ERR" || true
            die "parted resizepart failed"
        fi
    fi
    rm -f "$RESIZE_ERR" || true

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    FSTYPE="$(blkid -o value -s TYPE "$DATA_PART" 2>/dev/null || true)"
    if [[ -z "$FSTYPE" ]]; then
        log "no filesystem on $DATA_PART; creating ext4 with label=data"
        mkfs.ext4 -F -L data "$DATA_PART" 1>&2
        FSTYPE="ext4"
    fi
    if [[ "$FSTYPE" != "ext4" ]]; then
        die "unsupported filesystem on $DATA_PART: $FSTYPE"
    fi

    log "growing filesystem on $DATA_PART"
    e2fsck -f -p "$DATA_PART" 1>&2 || true
    resize2fs "$DATA_PART" 1>&2

    touch "$STAMP"
    log "growth complete"
}

main "$@"
