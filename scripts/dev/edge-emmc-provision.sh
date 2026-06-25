#!/usr/bin/env bash
# Write an EDGE_BOOT_TARGET=emmc image to the RZ/V2L eMMC user area, from a
# running Linux that can see the eMMC (mmcblkX with a mmcblkXboot0).
#
# The eMMC bootloader (BL2 + FIP) lives in the hardware boot partition
# (mmcblkXboot0), NOT the user area. For a BLANK eMMC the boot0 bootloader is
# written with the serial Flash Writer (RZ/V2L Start-up Guide, "Writing
# Bootloader for eMMC Boot") — see docs/dev/emmc-provisioning.md. This script
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

BASE="$(basename "$TARGET")"
BOOT0="/dev/${BASE}boot0"
BOOT0_FORCE_RO="/sys/block/${BASE}boot0/force_ro"

# Safety 1: target must expose a hardware boot partition (i.e. be eMMC).
[ -b "$BOOT0" ] || die "$TARGET has no ${BASE}boot0 — not an eMMC, refusing"
# Safety 2: target must not carry the running rootfs.
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
case "$ROOT_SRC" in
    "/dev/${BASE}"p*|"/dev/${BASE}") die "refusing: $TARGET carries the running rootfs ($ROOT_SRC)" ;;
esac

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
       the serial Flash Writer per docs/dev/emmc-provisioning.md).
    2. Power off; set switches to eMMC (SW1-2=OFF, SW11=ON,OFF,OFF,ON).
    3. Power on. First boot rewrites the U-Boot env (CRC invalid is expected);
       reboot once to settle. systemd-repart grows /data.
  Recovery: reselect SD/eSD boot to fall back to the SD unchanged.
EOF
