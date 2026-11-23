#!/usr/bin/env bash
# Write a LAYOUT=emmc image to the RZ/V2L eMMC user area, from a
# running Linux that can see the eMMC (mmcblkX with a mmcblkXboot0).
#
# The eMMC bootloader (BL2 + FIP) lives in the hardware boot partition
# (mmcblkXboot0), NOT the user area. For a BLANK eMMC the boot0 bootloader is
# written with the serial Flash Writer (RZ/V2L Start-up Guide, "Writing
# Bootloader for eMMC Boot") — see docs/dev/emmc/rzv2l.md. This script
# writes the GPT user-area image; if boot0 is writable from Linux it can also
# program boot0 (--bl2/--fip), at the Start-up-Guide sectors:
#   BL2 -> mmcblkXboot0 sector 1
#   FIP -> mmcblkXboot0 sector 256
#
# Run on the board with the eMMC visible (SW1-2=eMMC), as root:
#   edge-emmc-provision --wic <image.wic[.zst]> --target /dev/mmcblkX \
#                       [--bl2 bl2_bp_mmc-*.bin --fip fip-*.bin]
#
# Recovery: a bad eMMC provision does not touch any SD — reselect SD/eSD boot.

set -euo pipefail

WIC=""; TARGET=""; BL2=""; FIP=""; ASSUME_YES=0

log()  { printf '[emmc-provision] %s\n' "$*"; }
warn() { printf '[emmc-provision][WARN] %s\n' "$*" >&2; }
die()  { printf '[emmc-provision][ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

usage() {
    cat <<EOF
Usage: edge-emmc-provision --wic <img> --target <dev> [--bl2 <f> --fip <f>] [--yes]

  --wic <path>    edge-rzv2l-emmc image (.wic or .wic.zst), pure GPT user area.
  --target <dev>  eMMC user-area device (e.g. /dev/mmcblk0). Verified to expose
                  <dev>boot0; refuses the device carrying the running rootfs.
  --bl2 <path>    Optional: bl2_bp_mmc-<machine>[_pmic].bin -> boot0 sector 1.
  --fip <path>    Optional: fip-<machine>[_pmic].bin       -> boot0 sector 256.
                  Omit both for a blank eMMC where boot0 is programmed via the
                  serial Flash Writer instead (see the doc).
  --yes           Skip the confirmation prompt.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --wic)    WIC=${2:?}; shift 2 ;;
        --target) TARGET=${2:?}; shift 2 ;;
        --bl2)    BL2=${2:?}; shift 2 ;;
        --fip)    FIP=${2:?}; shift 2 ;;
        --yes)    ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

[ -n "$WIC" ]    || { usage; die "--wic is required"; }
[ -n "$TARGET" ] || { usage; die "--target is required"; }
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$WIC" ]    || die "wic image not found: $WIC"
[ -b "$TARGET" ] || die "target is not a block device: $TARGET"

need_cmd dd; need_cmd partprobe; need_cmd sfdisk

# Programming boot0 from Linux requires both loaders and mmc-utils.
PROGRAM_BOOT0=0
if [ -n "$BL2" ] || [ -n "$FIP" ]; then
    [ -n "$BL2" ] && [ -n "$FIP" ] || die "--bl2 and --fip must be given together"
    [ -f "$BL2" ] || die "BL2 not found: $BL2"
    [ -f "$FIP" ] || die "FIP not found: $FIP"
    need_cmd mmc
    PROGRAM_BOOT0=1
fi

# A /dev/disk/by-* alias resolves to the kernel name the guards compare.
TARGET="$(readlink -f "$TARGET")"
BASE="$(basename "$TARGET")"
BOOT0="/dev/${BASE}boot0"
SYSFS="${EDGE_SYSFS:-/sys}"

# Whole-disk names backing block device MAJ:MIN, through device-mapper
# (dm-verity, dm-crypt, LVM) slaves, loop backing files and partition
# parents. Non-zero if unresolvable.
backing_disks() {
    local node s mm bf
    [ -n "${1:-}" ] || return 1
    node="$(readlink -f "$SYSFS/dev/block/$1" 2>/dev/null)" || return 1
    [ -d "$node" ] || return 1
    case "$(basename "$node")" in
    loop*)
        bf="$(cat "$node/loop/backing_file" 2>/dev/null)" || return 1
        [ -n "$bf" ] || return 1
        if [ -b "$bf" ]; then
            mm="$(cat "$SYSFS/class/block/$(basename "$(readlink -f "$bf")")/dev")" || return 1
        else
            mm="$(stat -c '%Hd:%Ld' "$bf" 2>/dev/null)" || return 1
        fi
        backing_disks "$mm"
        return
        ;;
    esac
    if [ -d "$node/slaves" ] && [ -n "$(ls -A "$node/slaves")" ]; then
        for s in "$node"/slaves/*; do
            mm="$(cat "$s/dev")" || return 1
            backing_disks "$mm" || return 1
        done
    elif [ -f "$node/partition" ]; then
        basename "$(dirname "$node")"
    else
        basename "$node"
    fi
}
BOOT0_FORCE_RO="/sys/block/${BASE}boot0/force_ro"

# Safety 1: target must expose a hardware boot partition (i.e. be eMMC).
[ -b "$BOOT0" ] || die "$TARGET has no ${BASE}boot0 — not an eMMC, refusing"
[ -f "$SYSFS/class/block/$BASE/partition" ] && die "$TARGET is a partition; give the whole eMMC (e.g. /dev/mmcblk0)"
[ -d "$SYSFS/class/block/$BASE" ] || die "$TARGET is not in $SYSFS/class/block; refusing"

# Safety 2: target must be in use by nothing. Under dm-verity the root is
# /dev/dm-0, so the device name alone does not say which disk it lives on.
#  a) no device-mapper, md or other holder on the disk or a partition
#  b) every mounted filesystem resolved to its disks; an anonymous device
#     (major 0) is accepted only for filesystems with no block device
#  c) every active swap area resolved the same way
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
ROOT_MM="$(findmnt -n -o MAJ:MIN / 2>/dev/null | tr -d "[:space:]" || true)"
[ -n "$ROOT_MM" ] || die "cannot determine the device behind /; refusing"

DISK_DIR="$(readlink -f "$SYSFS/class/block/$BASE")"
for d in "$DISK_DIR" "$DISK_DIR"/"$BASE"p*; do
    [ -d "$d/holders" ] || continue
    held="$(ls -A "$d/holders")"
    [ -z "$held" ] || die "refusing: $(basename "$d") is held by $(echo $held) (device-mapper or md in use)"
done

in_target() { # in_target <maj:min> <what>
    local disks d
    disks="$(backing_disks "$1")" || die "cannot resolve the disk behind $2 ($1); refusing"
    for d in $disks; do
        [ "$d" = "$BASE" ] && die "refusing: $TARGET backs $2 ($1)"
    done
    return 0
}

MOUNTS="$(findmnt -rn -o MAJ:MIN,FSTYPE,TARGET 2>/dev/null)" || die "cannot list mounts; refusing"
while read -r mm fstype mnt; do
    [ -n "$mm" ] || continue
    case "$mm" in
    0:*)
        case "$fstype" in
            tmpfs|devtmpfs|ramfs|proc|sysfs|cgroup|cgroup2|overlay|nfs|nfs4|autofs|\
            mqueue|debugfs|tracefs|securityfs|pstore|bpf|configfs|fusectl|devpts|\
            hugetlbfs|efivarfs|binfmt_misc|rpc_pipefs|selinuxfs|nsfs|fuse.*) continue ;;
            *) die "cannot resolve the disk behind $mnt ($fstype on an anonymous device); refusing" ;;
        esac ;;
    esac
    in_target "$mm" "the mounted filesystem $mnt"
done <<MOUNTS_EOF
$MOUNTS
MOUNTS_EOF

PROCFS="${EDGE_PROC:-/proc}"
[ -r "$PROCFS/swaps" ] || die "cannot read $PROCFS/swaps; refusing"
while read -r name _; do
    [ -n "$name" ] || continue
    if [ -b "$name" ]; then
        mm="$(cat "$SYSFS/class/block/$(basename "$(readlink -f "$name")")/dev" 2>/dev/null)" \
            || die "cannot resolve swap $name; refusing"
    else
        mm="$(stat -c '%Hd:%Ld' "$name" 2>/dev/null)" || die "cannot resolve swap $name; refusing"
    fi
    in_target "$mm" "the active swap $name"
done <<SWAPS_EOF
$(tail -n +2 "$PROCFS/swaps")
SWAPS_EOF

log "Target eMMC:  $TARGET  (boot partition: $BOOT0)"
log "GPT image:    $WIC"
[ "$PROGRAM_BOOT0" -eq 1 ] && log "boot0 program: BL2=$BL2  FIP=$FIP" || log "boot0 program: skipped (use serial Flash Writer for a blank eMMC)"
log "Running root: ${ROOT_SRC:-unknown} (untouched)"

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '[emmc-provision] This ERASES %s. Type YES to continue: ' "$TARGET"
    read -r reply; [ "$reply" = "YES" ] || die "aborted"
fi

# 1. Write the pure-GPT image to the eMMC user area.
BMAP="${WIC%.zst}.bmap"
if [ "${WIC##*.}" = "zst" ]; then
    if command -v bmaptool >/dev/null 2>&1 && [ -f "$BMAP" ]; then
        log "Writing image with bmaptool (sparse) ..."
        bmaptool copy --bmap "$BMAP" "$WIC" "$TARGET"
    else
        need_cmd zstd
        log "Writing image via zstd | dd ..."
        zstd -dcf "$WIC" | dd of="$TARGET" bs=4M conv=fsync status=progress
    fi
else
    log "Writing image via dd ..."
    dd if="$WIC" of="$TARGET" bs=4M conv=fsync status=progress
fi
sync; partprobe "$TARGET" || true

sfdisk -l "$TARGET" 2>/dev/null | grep -qi 'Disklabel type: gpt' \
    || die "user area is not GPT after write — aborting"

# 2. Optionally program boot0 from Linux (Start-up Guide sectors).
if [ "$PROGRAM_BOOT0" -eq 1 ]; then
    log "Programming $BOOT0: BL2 @ sector 1, FIP @ sector 256 ..."
    [ -w "$BOOT0_FORCE_RO" ] && echo 0 > "$BOOT0_FORCE_RO" || warn "could not clear force_ro"
    dd if="$BL2" of="$BOOT0" bs=512 seek=1   conv=fsync status=none
    dd if="$FIP" of="$BOOT0" bs=512 seek=256 conv=fsync status=none
    sync
    [ -w "$BOOT0_FORCE_RO" ] && echo 1 > "$BOOT0_FORCE_RO" || true
    # PARTITION_CONFIG (EXT_CSD 0xB3) = 0x08: boot0 enabled, no ACK.
    mmc bootpart enable 1 0 "$TARGET"
    # BOOT_BUS_CONDITIONS (EXT_CSD 0xB1) = 0x02: x8 boot bus width.
    mmc bootbus set single_backward x1 x8 "$TARGET" 2>/dev/null \
        || warn "could not set boot bus width (EXT_CSD 0xB1) — set via Flash Writer if eMMC boot fails"
fi

# 3. Report.
log "Verification:"
sfdisk -l "$TARGET" 2>/dev/null | sed -n '/Disklabel type/p;/Device/,$p'
mmc extcsd read "$TARGET" 2>/dev/null | grep -iE 'PARTITION_CONFIG|BOOT_BUS|BOOT_PARTITION_ENABLE' || true

cat <<EOF
[emmc-provision] User-area image written.
  Next:
    1. Ensure boot0 holds BL2+FIP (this run if --bl2/--fip were given, else via
       the serial Flash Writer per docs/dev/emmc/rzv2l.md).
    2. Power off; set switches to eMMC (SW1-2=OFF, SW11=ON,OFF,OFF,ON).
    3. Power on. First boot rewrites the U-Boot env (CRC invalid is expected);
       reboot once to settle. systemd-repart grows /data.
  Recovery: reselect SD/eSD boot to fall back to the SD unchanged.
EOF
