#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Guarded RZ/V2L bootchain updater (BL2 + FIP).
#
# The RZ/V2L bootchain (BL2 at the ROM-expected offset, then FIP = TF-A BL31 +
# OP-TEE BL32 + U-Boot BL33) lives in single-copy storage: QSPI (mtd
# "bl2"/"fip"), eSD raw offsets, or eMMC boot0. The ROM tries one location per
# medium and does not fall back, and BL2 reads one FIP from the boot medium.
# A write interrupted part-way leaves that medium unbootable; recovery is
# another boot medium (SW11) with --restore, the SCIF Flash Writer (QSPI and
# eMMC only, not SD), or rewriting the SD card on a host.
#
# Guard chain, all before the first write:
#   1. root, one run at a time (flock), required --mode/--variant and tools;
#      --variant matches the detected PMIC (RAA215300 present => pmic)
#   2. staged artifact SHA-256 == manifest; BL2 carries a valid header
#   3. QSPI: /proc/mtd labels "bl2"/"fip"; eSD: an SD card whose partitions all
#      start after the raw bootchain area, FIP ending before the U-Boot env;
#      eMMC: EXT_CSD enables boot0 for boot with an 8-bit boot bus
#   4. the FIP's U-Boot DTB trusts the key behind each installed slot FIT
#   5. every target holds offset+size
# Then: skip if BL2 and FIP are both current; else back up both to
# /data/.../<run-id>/ (survives reboot; a QSPI partition whole), invalidate the
# BL2 header, write the FIP if it differs, write BL2 with its header last, read
# both back. Until the header is rewritten the ROM rejects the medium and
# enters SCIF download mode: documented for eSD, observed on QSPI for a zeroed
# signature, a zeroed signature + size word, and an erased header. eMMC is
# neither documented nor observed.
#
# eMMC: writes boot0 only and refuses while EXT_CSD enables boot1. The RAUC
# bootloader slot (rzv2l-bootchain-bundle) alternates boot0/boot1 and is the
# eMMC update path; this tool is the lab/recovery path for a boot0-enabled eMMC.
#
# The FIP address is a TF-A pin property (QSPI_FIP_ADDR and 0x20000 below match
# TF-A 2.10.5; earlier Renesas TF-A placed it at 0x10000 on SD).
#
# --restore <run-id> writes a run's backup back as a pair through the same
# guards and ordering; a run holding one part is completed from the medium.
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR=${ROOT_DIR:-/usr/share/rzv2l-boot}
MANIFEST=${MANIFEST:-${ROOT_DIR}/manifest.tsv}
MMC_DEV=${MMC_DEV:-/dev/mmcblk0}
MTD_BL2=${MTD_BL2:-/dev/mtd0}
MTD_FIP=${MTD_FIP:-/dev/mtd1}
# Expected QSPI partition labels (/proc/mtd). Override only for a board whose
# mtd layout genuinely differs — the check exists to stop a write to the wrong
# flash region.
MTD_BL2_LABEL=${MTD_BL2_LABEL:-bl2}
MTD_FIP_LABEL=${MTD_FIP_LABEL:-fip}
# Absolute QSPI address BL2 reads the FIP from: TF-A RZG2L_SPIROM_FIP_BASE
# (SPIROM base + 0x20000). The Linux "fip" partition starts below it, so the
# FIP goes at (this - partition start) inside the partition.
QSPI_FIP_ADDR=${QSPI_FIP_ADDR:-0x20000}
# Must survive a reboot: /var/lib is a volatile overlay on the verity rootfs.
BACKUP_DIR=${BACKUP_DIR:-/data/rzv2l-boot/backup}
BOOT_DIR=${BOOT_DIR:-/boot}
# 1 = accept a --variant that disagrees with the detected PMIC.
ALLOW_VARIANT_MISMATCH=${ALLOW_VARIANT_MISMATCH:-0}
# eSD: U-Boot CONFIG_ENV_OFFSET (the FIP must end before it), and the end of the
# raw bootchain area (the first partition starts at or after it).
ESD_ENV_OFFSET=${ESD_ENV_OFFSET:-0x1F0000}
SD_BOOTCHAIN_END=${SD_BOOTCHAIN_END:-0x400000}
LOCK_FILE=${LOCK_FILE:-/run/lock/rzv2l-bootloader-update.lock}
# The ROM loads BL2 into on-chip RAM 0x12000-0x2EFFF.
BL2_MAX=$((0x1D000))

MODE=""
VARIANT=""
RESTORE=""
ASSUME_YES=0
DRY_RUN=0
WRITES=0
PLANNED=0
# One directory per run: a second run within the same second, or a restore of
# a run started in the same second, must not write into an existing run.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "${BACKUP_DIR}/${RUN_ID}" ] || RUN_ID="${RUN_ID}-$$"
RUN_DIR="${BACKUP_DIR}/${RUN_ID}"

log()  { printf '[rzv2l-bootloader-update] %s\n' "$*"; }
die()  { printf '[rzv2l-bootloader-update][ERROR] %s\n' "$*" >&2; exit 1; }

# $1 = operation name; reports what the run actually did.
finish() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$1 dry-run complete: ${PLANNED} region(s) would be written; nothing written."
    elif [ "$WRITES" -eq 0 ]; then
        log "$1 complete: bootchain already current; nothing written, no reboot needed."
    else
        log "$1 complete: ${WRITES} region(s) written. Reboot is required for the bootchain to take effect."
    fi
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

usage() {
    cat <<'EOF'
Usage:
  rzv2l-bootloader-update --mode qspi|esd|emmc --variant pmic|non-pmic [--yes] [--dry-run]
  rzv2l-bootloader-update --restore <run-id> [--yes] [--dry-run]

Writes BL2 + FIP to the selected bootchain target after verifying staged
artifacts against the manifest, backing up current content, and reads back to
confirm. Reboot is required after a successful update.

Options:
  --mode <mode>        Target (required): qspi (QSPI flash), esd (SD raw), emmc
  --variant <variant>  Artifact variant (required): pmic, non-pmic
  --yes                Non-interactive confirmation
  --restore <run-id>   Write back the backup of an earlier run
                       (directory name under BACKUP_DIR; list with ls)
  --dry-run            Print planned actions only; write nothing
  --help               Show this help

Environment overrides:
  ROOT_DIR=/usr/share/rzv2l-boot   MANIFEST=$ROOT_DIR/manifest.tsv
  MMC_DEV=/dev/mmcblk0   MTD_BL2=/dev/mtd0   MTD_FIP=/dev/mtd1
  MTD_BL2_LABEL=bl2   MTD_FIP_LABEL=fip   BACKUP_DIR=/data/rzv2l-boot/backup
  ALLOW_VARIANT_MISMATCH=0 (1 = accept a --variant that disagrees with the PMIC)
  ESD_ENV_OFFSET=0x1F0000   SD_BOOTCHAIN_END=0x400000
  LOCK_FILE=/run/lock/rzv2l-bootloader-update.lock

Recovery: an interrupted write leaves the medium unbootable. Boot another
medium (SW11) and --restore, use the SCIF Flash Writer (QSPI, eMMC), or rewrite
the SD card on a host (see docs/dev/bootchain/rzv2l.md).
EOF
}

manifest_get() {
    local filename="$1" mode="$2" variant="$3" col="$4"
    awk -F'\t' -v n="$filename" -v m="$mode" -v v="$variant" -v c="$col" '
        NR == 1 { next }
        $1 == n && $4 == m && $7 == v { print $c; exit 0 }
    ' "$MANIFEST"
}

pick_artifact() {
    local prefix="$1" variant="$2" f
    if [ "$variant" = "pmic" ]; then
        for f in "${ROOT_DIR}/${prefix}-"*"_pmic.bin"; do
            [ -f "$f" ] && { echo "$f"; return 0; }
        done
    else
        for f in "${ROOT_DIR}/${prefix}-"*".bin"; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in *_pmic.bin) continue ;; esac
            echo "$f"; return 0
        done
    fi
    return 1
}

# Byte size of a target region we are allowed to write into.
target_capacity() {
    local target="$1"
    case "$target" in
        /dev/mtd*)
            local n; n=$(basename "$target")
            cat "/sys/class/mtd/${n}/size" 2>/dev/null && return 0
            # fall back to mtd_debug
            mtd_debug info "$target" 2>/dev/null | awk -F'=' '/mtd.size/{gsub(/ /,"",$2);print $2;exit}'
            ;;
        *)  # block device / partition: size in bytes
            blockdev --getsize64 "$target" 2>/dev/null
            ;;
    esac
}

readback_hash() {
    local target="$1" offset_bytes="$2" size_bytes="$3"
    # Without dropping the buffer cache a readback can be served from the
    # pages just written, not from the medium.
    case "$target" in /dev/mtd*) ;; *) blockdev --flushbufs "$target" ;; esac
    dd if="$target" iflag=skip_bytes,count_bytes skip="$offset_bytes" count="$size_bytes" bs=64K 2>/dev/null \
        | sha256sum | awk '{print $1}'
}

# Save what is about to be overwritten as <run-dir>/<tag>.img plus <tag>.meta
# (target, offset, size, sha256, write method), the input of --restore. An mtd
# partition is saved whole: flashcp erases whole erase blocks, so bytes past
# the end of a shorter new image are lost too.
backup_region() {
    local target="$1" offset="$2" size="$3" tag="$4" method="$5" sha
    case "$target" in /dev/mtd*) offset=0; size="$(target_capacity "$target")" ;; esac
    [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN back up $target @ $offset ($size B) -> ${RUN_DIR}/${tag}.img"; return 0; }
    install -d -m 0700 "$RUN_DIR"
    dd if="$target" iflag=skip_bytes,count_bytes skip="$offset" count="$size" bs=64K \
        of="${RUN_DIR}/${tag}.img" status=none
    sync
    sha="$(sha256sum "${RUN_DIR}/${tag}.img" | awk '{print $1}')"
    printf 'target\t%s\noffset\t%s\nsize\t%s\nsha256\t%s\nmethod\t%s\n' \
        "$target" "$offset" "$size" "$sha" "$method" > "${RUN_DIR}/${tag}.meta"
    sync
    log "backed up $tag ($target @ $offset, $size B, $sha) -> ${RUN_DIR}/"
}

# Refuse if offset+size does not fit the target. Called for every artifact
# before the first write, so one bad artifact cannot leave the other written.
check_fits() {
    local src="$1" target="$2" offset="$3" tag="$4" size cap
    size="$(stat -c%s "$src")"
    cap="$(target_capacity "$target")"
    [ -n "$cap" ] || die "cannot determine capacity of $target — refusing to write $tag"
    [ $(( offset + size )) -le "$cap" ] \
        || die "$tag would overflow $target: offset($offset)+size($size) > capacity($cap)"
}

# --- pair write: invalidate the BL2 header first, write it last ---------------
# The ROM takes the BL2 size from a boot-parameter header (signature AA55 at
# +0x1FE). For eSD the hardware manual documents that the signature is checked
# on 7 copies and that all-invalid enters SCIF download mode; for QSPI and eMMC
# it documents the same layout but not the check. The QSPI ROM rejects an
# invalid header the same way. An invalid header therefore stops the ROM from
# running a BL2 that reads a half-written FIP; on QSPI the size word is zeroed
# as well. So: invalidate the header, write the FIP, write the
# BL2 body, write the header last. BL2 is rewritten on every run that changes
# anything, because its header was invalidated.
#
# Layout of the pair on the target medium, set by set_layout:
#   L_METHOD   flashcp (QSPI) | dd (eSD, eMMC)
#   L_BL2_TGT  L_BL2_OFF  L_HDR_LEN   BL2 image = L_HDR_LEN header bytes + body
#   L_FIP_TGT  L_FIP_OFF
L_METHOD=""; L_BL2_TGT=""; L_BL2_OFF=0; L_HDR_LEN=0; L_FIP_TGT=""; L_FIP_OFF=0
INVALIDATED=0
RO_SYSFS=""

set_layout() {  # <qspi|esd|emmc> <fip offset in L_FIP_TGT>
    case "$1" in
        qspi) L_METHOD="flashcp"; L_BL2_TGT="$MTD_BL2"; L_BL2_OFF=0; L_HDR_LEN=512
              L_FIP_TGT="$MTD_FIP"; L_FIP_OFF="$2" ;;
        esd)  L_METHOD="dd"; L_BL2_TGT="$MMC_DEV"; L_BL2_OFF=$((0x200)); L_HDR_LEN=$((7 * 512))
              L_FIP_TGT="$MMC_DEV"; L_FIP_OFF="$2" ;;
        emmc) L_METHOD="dd"; L_BL2_TGT="${MMC_DEV}boot0"; L_BL2_OFF=$((0x200)); L_HDR_LEN=512
              L_FIP_TGT="${MMC_DEV}boot0"; L_FIP_OFF="$2" ;;
        *)    die "internal: unknown layout $1" ;;
    esac
}

on_exit() {
    [ -n "$RO_SYSFS" ] && [ -e "$RO_SYSFS" ] && { echo 1 > "$RO_SYSFS"; } 2>/dev/null || true
    if [ "$INVALIDATED" -eq 1 ]; then
        printf '[rzv2l-bootloader-update][ERROR] %s\n' \
            "the BL2 header on ${L_BL2_TGT} is invalidated and the pair is incomplete: this medium does not boot. Do NOT reboot from it: re-run the update, or --restore ${RUN_ID}." >&2
    fi
}
trap on_exit EXIT

# 0 if the first header copy in file $1 carries the AA55 signature.
header_valid() {
    [ "$(od -An -tx1 -j510 -N2 "$1" 2>/dev/null | tr -d ' \n')" = 55aa ]
}

# Same check on the medium (first header copy at L_BL2_OFF): 0 = valid,
# 1 = invalid, 2 = the medium could not be read.
header_valid_on_medium() {
    local t; t="$(mktemp /tmp/rzv2l-hdr.XXXXXX)"
    case "$L_BL2_TGT" in /dev/mtd*) ;; *) blockdev --flushbufs "$L_BL2_TGT" || { rm -f "$t"; return 2; } ;; esac
    dd if="$L_BL2_TGT" of="$t" iflag=skip_bytes,count_bytes skip="$L_BL2_OFF" count=512 status=none \
        || { rm -f "$t"; return 2; }
    [ "$(stat -c%s "$t")" -eq 512 ] || { rm -f "$t"; return 2; }
    if header_valid "$t"; then rm -f "$t"; return 0; fi
    rm -f "$t"; return 1
}

# Write file $1 to target $2 at byte offset $3.
raw_write() {
    local src="$1" target="$2" offset="$3"
    case "$L_METHOD" in
        flashcp)
            if [ "$offset" -eq 0 ]; then
                flashcp -v "$src" "$target"
            else
                # Keep the partition's current bytes before the offset, append
                # the image, and write that from the partition start.
                local img; img="$(mktemp /tmp/rzv2l-bl.XXXXXX)"
                head -c "$offset" "$target" > "$img"
                cat "$src" >> "$img"
                flashcp -v "$img" "$target"
                rm -f "$img"
            fi ;;
        dd) dd if="$src" of="$target" oflag=seek_bytes seek="$offset" bs=64K conv=fsync,notrunc status=none ;;
    esac
    sync
}

# QSPI: program the size word and the signature to 0 without an erase (NOR
# programming only clears bits). eSD/eMMC: zero every header copy.
invalidate_bl2_header() {
    case "$L_METHOD" in
        flashcp)
            local z; z="$(mktemp /tmp/rzv2l-z.XXXXXX)"
            printf '\0\0\0\0' > "$z"
            mtd_debug write "$L_BL2_TGT" 510 2 "$z" >/dev/null
            mtd_debug write "$L_BL2_TGT" 0 4 "$z" >/dev/null
            rm -f "$z" ;;
        dd)
            head -c "$L_HDR_LEN" /dev/zero \
                | dd of="$L_BL2_TGT" oflag=seek_bytes seek="$L_BL2_OFF" bs=64K conv=fsync,notrunc status=none ;;
    esac
    sync
    local rc=0
    header_valid_on_medium || rc=$?
    [ "$rc" -ne 2 ] || die "cannot read back the BL2 header on ${L_BL2_TGT} after invalidation — refusing to continue (FIP not written)"
    [ "$rc" -eq 1 ] || die "BL2 header on ${L_BL2_TGT} still valid after invalidation — refusing to continue (nothing else written)"
    INVALIDATED=1
    log "bl2 header invalidated on ${L_BL2_TGT} (the medium does not boot until the pair is complete)"
}

# QSPI: flashcp --wr-last writes the first 512 bytes (the header) last.
# eSD/eMMC: body, flush, then the header copies.
write_bl2_header_last() {
    local src="$1"
    case "$L_METHOD" in
        flashcp) flashcp -v -l 512 "$src" "$L_BL2_TGT" ;;
        dd)
            dd if="$src" iflag=skip_bytes skip="$L_HDR_LEN" of="$L_BL2_TGT" \
                oflag=seek_bytes seek=$((L_BL2_OFF + L_HDR_LEN)) bs=64K conv=fsync,notrunc status=none
            blockdev --flushbufs "$L_BL2_TGT"
            head -c "$L_HDR_LEN" "$src" \
                | dd of="$L_BL2_TGT" oflag=seek_bytes seek="$L_BL2_OFF" bs=64K conv=fsync,notrunc status=none ;;
    esac
    sync
}

# pair_write <bl2-src> <bl2-sha256> <fip-src> <fip-sha256>
# Skip if both are current; otherwise back up both, invalidate the BL2 header,
# write the FIP if it differs, write BL2 header-last, read both back.
pair_write() {
    local bl2_src="$1" bl2_exp="$2" fip_src="$3" fip_exp="$4"
    local bl2_size fip_size bl2_cur fip_cur h
    bl2_size="$(stat -c%s "$bl2_src")"; fip_size="$(stat -c%s "$fip_src")"
    check_fits "$fip_src" "$L_FIP_TGT" "$L_FIP_OFF" fip
    check_fits "$bl2_src" "$L_BL2_TGT" "$L_BL2_OFF" bl2
    header_valid "$bl2_src" || die "BL2 source $(basename "$bl2_src") has no valid boot-parameter header (AA55 at 0x1FE) — refusing"
    [ "$L_METHOD" = flashcp ] && { need_cmd mtd_debug; [ "$L_BL2_OFF" -eq 0 ] || die "internal: QSPI BL2 offset must be 0"; }

    bl2_cur="$(readback_hash "$L_BL2_TGT" "$L_BL2_OFF" "$bl2_size")"
    fip_cur="$(readback_hash "$L_FIP_TGT" "$L_FIP_OFF" "$fip_size")"
    [ "$fip_cur" = "$fip_exp" ] && log "fip already current on ${L_FIP_TGT} (hash match) — skipping write"
    if [ "$bl2_cur" = "$bl2_exp" ] && [ "$fip_cur" = "$fip_exp" ]; then
        log "bl2 already current on ${L_BL2_TGT} (hash match) — skipping write"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN would back up bl2 + fip, invalidate the BL2 header on ${L_BL2_TGT}"
        [ "$fip_cur" = "$fip_exp" ] || { log "DRY-RUN would write fip (${fip_size} B) to ${L_FIP_TGT} @ offset ${L_FIP_OFF} via ${L_METHOD}"; PLANNED=$((PLANNED + 1)); }
        log "DRY-RUN would write bl2 (${bl2_size} B) to ${L_BL2_TGT} @ offset ${L_BL2_OFF} via ${L_METHOD}, header last"
        PLANNED=$((PLANNED + 1))
        return 0
    fi

    backup_region "$L_BL2_TGT" "$L_BL2_OFF" "$bl2_size" bl2 "$L_METHOD"
    backup_region "$L_FIP_TGT" "$L_FIP_OFF" "$fip_size" fip "$L_METHOD"

    invalidate_bl2_header
    if [ "$fip_cur" != "$fip_exp" ]; then
        raw_write "$fip_src" "$L_FIP_TGT" "$L_FIP_OFF"
        h="$(readback_hash "$L_FIP_TGT" "$L_FIP_OFF" "$fip_size")"
        [ "$h" = "$fip_exp" ] || die "readback hash mismatch for fip on ${L_FIP_TGT} @ offset ${L_FIP_OFF}"
        log "fip written and verified on ${L_FIP_TGT}"
        WRITES=$((WRITES + 1))
    fi
    write_bl2_header_last "$bl2_src"
    h="$(readback_hash "$L_BL2_TGT" "$L_BL2_OFF" "$bl2_size")"
    [ "$h" = "$bl2_exp" ] || die "readback hash mismatch for bl2 on ${L_BL2_TGT} @ offset ${L_BL2_OFF}"
    INVALIDATED=0
    log "bl2 written header-last and verified on ${L_BL2_TGT}"
    WRITES=$((WRITES + 1))
}

# The SMARC EVK with the RAA215300 PMIC needs the _pmic BL2; the wrong variant
# leaves a board that does not boot. Detect from the device tree (independent of
# driver binding), falling back to the i2c device name.
detected_variant() {
    if grep -qs 'renesas,raa215300' /proc/device-tree/soc/*/pmic@*/compatible \
       || grep -qsx 'raa215300' /sys/bus/i2c/devices/*/name; then
        echo pmic
    else
        echo non-pmic
    fi
}

check_variant() {
    local det; det="$(detected_variant)"
    [ "$det" = "$VARIANT" ] && { log "variant check: board is $det"; return 0; }
    [ "$ALLOW_VARIANT_MISMATCH" = "1" ] && { log "WARN: --variant $VARIANT but board looks $det (override set)"; return 0; }
    die "variant guard: --variant $VARIANT but this board is $det (RAA215300 PMIC $( [ "$det" = pmic ] && echo present || echo absent )) — refusing; set ALLOW_VARIANT_MISMATCH=1 only if detection is wrong"
}

# Offset of the TF-A FIP address inside the "fip" partition. Refuses if the
# partition layout does not contain it or the offset is not erase-aligned.
qspi_fip_offset() {
    local n start erase bl2start off
    n="$(basename "$MTD_FIP")"
    start="$(cat "/sys/class/mtd/${n}/offset" 2>/dev/null)" || true
    erase="$(cat "/sys/class/mtd/${n}/erasesize" 2>/dev/null)" || true
    bl2start="$(cat "/sys/class/mtd/$(basename "$MTD_BL2")/offset" 2>/dev/null)" || true
    [ -n "$start" ] && [ -n "$erase" ] || die "cannot read ${MTD_FIP} offset/erasesize from sysfs"
    [ "$bl2start" = "0" ] || die "${MTD_BL2} does not start at QSPI 0 (offset ${bl2start:-?}) — BL2 must sit at the ROM address"
    off=$(( QSPI_FIP_ADDR - start ))
    [ "$off" -ge 0 ] || die "QSPI FIP address $(printf '%#x' "$QSPI_FIP_ADDR") is below ${MTD_FIP} (starts $(printf '%#x' "$start"))"
    [ $(( off % erase )) -eq 0 ] || die "FIP offset $(printf '%#x' "$off") in ${MTD_FIP} is not erase-aligned ($erase)"
    echo "$off"
}

check_mtd_label() {
    local dev="$1" want="$2" n label
    n=$(basename "$dev")
    label=$(awk -F'"' -v d="${n}:" '$0 ~ "^"d {print $2; exit}' /proc/mtd 2>/dev/null || true)
    [ -n "$label" ] || die "cannot read /proc/mtd label for $dev"
    [ "$label" = "$want" ] \
        || die "mtd layout guard: $dev is labelled '$label', expected '$want' — refusing to write (wrong flash region)"
}

# SW1-2 routes SDHI0 to the microSD or the eMMC, so ${MMC_DEV} is whichever is
# connected. Refuse a mode that does not match the connected medium: esd on an
# eMMC would overwrite the GPT header at 0x200.
check_mmc_medium() {
    local want="$1" type
    type=$(cat "/sys/block/$(basename "$MMC_DEV")/device/type" 2>/dev/null || true)
    [ "$type" = "$want" ] \
        || die "medium guard: ${MMC_DEV} is '${type:-unknown}', --mode ${MODE:-restore} needs '${want}' (SW1-2 selects microSD or eMMC) — refusing"
    if [ "$want" = SD ] && [ -e "${MMC_DEV}boot0" ]; then
        die "medium guard: ${MMC_DEV} has a boot0 partition (eMMC), not an SD card — refusing"
    fi
}

# Make eMMC boot0 writable for the writes that follow; on_exit restores
# read-only on every exit path, including a refusal or failed readback.
boot0_writable() {
    local ro="$1"
    [ "$DRY_RUN" -eq 0 ] && [ -e "$ro" ] || return 0
    RO_SYSFS="$ro"
    echo 0 > "$ro"
}

# A card written from this image keeps the raw bootchain area (BL2, FIP, U-Boot
# env) below SD_BOOTCHAIN_END; any partition starting inside it means a foreign
# card whose filesystem the writes would overwrite.
check_sd_layout() {
    local n s start min found=0
    n="$(basename "$MMC_DEV")"; min=$(( SD_BOOTCHAIN_END / 512 ))
    for s in /sys/block/"$n"/"$n"p*/start; do
        [ -f "$s" ] || continue
        found=1; start="$(cat "$s")"
        [ "$start" -ge "$min" ] || die "layout guard: ${MMC_DEV} partition $(basename "$(dirname "$s")") starts at sector ${start}, inside the bootchain area (below sector ${min}) — not a card written from this image; refusing"
    done
    [ "$found" -eq 1 ] || die "layout guard: ${MMC_DEV} has no partitions — not a card written from this image; refusing"
}

# On eSD the U-Boot environment follows the FIP (CONFIG_ENV_OFFSET).
check_esd_fip_end() {
    local size="$1"
    [ $(( L_FIP_OFF + size )) -le $(( ESD_ENV_OFFSET )) ] \
        || die "fip would overflow into the U-Boot environment: $(printf '%#x' "$L_FIP_OFF")+${size} > $(printf '%#x' "$ESD_ENV_OFFSET"); refusing"
}

# The ROM and BL2 load from the boot partition EXT_CSD[179] enables, with an
# 8-bit boot bus (EXT_CSD[177]). This tool writes boot0 (boot partition 1).
check_emmc_boot_config() {
    local out pc bb en
    need_cmd mmc
    out="$(mmc extcsd read "$MMC_DEV" 2>/dev/null)" || die "emmc guard: cannot read EXT_CSD of ${MMC_DEV}"
    pc="$(printf '%s\n' "$out" | sed -n 's/.*\[PARTITION_CONFIG: \(0x[0-9a-fA-F]*\)\].*/\1/p' | head -1)"
    bb="$(printf '%s\n' "$out" | sed -n 's/.*\[BOOT_BUS_CONDITIONS: \(0x[0-9a-fA-F]*\)\].*/\1/p' | head -1)"
    [ -n "$pc" ] && [ -n "$bb" ] || die "emmc guard: PARTITION_CONFIG/BOOT_BUS_CONDITIONS not found in EXT_CSD of ${MMC_DEV}"
    en=$(( (pc >> 3) & 7 ))
    [ "$en" -eq 1 ] || die "emmc guard: EXT_CSD PARTITION_CONFIG=${pc} enables boot partition ${en}, not boot0 — writing boot0 would not change what boots; use the RAUC bootloader slot (rzv2l-bootchain-authorize + rauc install); refusing"
    [ $(( bb & 3 )) -eq 2 ] || die "emmc guard: EXT_CSD BOOT_BUS_CONDITIONS=${bb} is not the 8-bit boot bus the ROM needs; refusing"
    [ $(( pc & 0x40 )) -eq 0 ] || die "emmc guard: EXT_CSD PARTITION_CONFIG=${pc} has BOOT_ACK set; the ROM needs it off; refusing"
    log "emmc guard: boot0 enabled for boot (PARTITION_CONFIG=${pc}), 8-bit boot bus"
}

# A restore writes only to the fixed bootchain locations, never to a target
# taken from the backup's .meta: <tag> <target> <offset> <method>. Sets
# RESTORE_MODE; both parts of a run must name the same medium.
RESTORE_MODE=""
restore_location_ok() {
    local tag="$1" target="$2" offset="$3" method="$4" m
    case "${tag} ${target} ${offset} ${method}" in
        "fip ${MTD_FIP} 0 flashcp"|"bl2 ${MTD_BL2} 0 flashcp") m=qspi ;;
        "fip ${MMC_DEV} $((0x20000)) dd"|"bl2 ${MMC_DEV} $((0x200)) dd") m=esd; check_mmc_medium SD; check_sd_layout ;;
        "fip ${MMC_DEV}boot0 $((0x20000)) dd"|"bl2 ${MMC_DEV}boot0 $((0x200)) dd") m=emmc; check_mmc_medium MMC; check_emmc_boot_config ;;
        *) die "backup ${tag}.meta names ${target} @ ${offset} via ${method}, not a bootchain location — refusing" ;;
    esac
    [ -z "$RESTORE_MODE" ] || [ "$RESTORE_MODE" = "$m" ] \
        || die "backup run mixes media (${RESTORE_MODE} and ${m}) — backup corrupt, refusing"
    RESTORE_MODE="$m"
}

# --- FIT anchor compatibility ------------------------------------------------
# U-Boot verifies the slot FITs against the public keys in its control DTB,
# which is appended to U-Boot inside the FIP. A FIP whose DTB does not trust
# the key that signed an installed slot FIT leaves that slot unbootable, so an
# update or restore is refused unless the candidate anchor holds, as
# required="conf", the key (by RSA modulus + exponent) behind each slot FIT.

# Write the first DTB carrying /signature/key-* found in file $1 to $2.
# LC_ALL=C: in a UTF-8 locale PCRE reads \xd0 as U+00D0, not the byte.
fip_anchor() {
    local src="$1" out="$2" off size
    for off in $(LC_ALL=C grep -obUaP '\xd0\x0d\xfe\xed' "$src" 2>/dev/null | cut -d: -f1); do
        size=$(od -An -tu4 --endian=big -j$((off + 4)) -N4 "$src" | tr -d ' ')
        [ -n "$size" ] && [ "$size" -gt 64 ] && [ "$size" -lt 1048576 ] || continue
        dd if="$src" of="$out" iflag=skip_bytes,count_bytes skip="$off" count="$size" status=none
        fdtget -l "$out" /signature 2>/dev/null | grep -q '^key-' && return 0
    done
    rm -f "$out"; return 1
}

key_fp() {  # dtb key-node -> sha256 of the key's modulus and exponent, or nothing
    fdtget -t x "$1" "/signature/$2" rsa,modulus >/dev/null 2>&1 || return 0
    { fdtget -t x "$1" "/signature/$2" rsa,modulus; fdtget -t x "$1" "/signature/$2" rsa,exponent; } \
        | sha256sum | awk '{print $1}'
}

required_fps() {  # dtb -> fingerprints of its required="conf" keys
    local k
    for k in $(fdtget -l "$1" /signature 2>/dev/null); do
        case "$k" in key-*) [ "$(fdtget "$1" "/signature/$k" required 2>/dev/null)" = conf ] && key_fp "$1" "$k" ;; esac
    done
    return 0
}

fit_signer() {  # fit conf -> key-name-hint of the config signature
    local s
    for s in $(fdtget -l "$1" "/configurations/$2" 2>/dev/null); do
        case "$s" in signature*) fdtget "$1" "/configurations/$2/$s" key-name-hint 2>/dev/null; return 0 ;; esac
    done
    return 0
}

# check_anchor_compat <candidate-dtb> <current-dtb or "">
check_anchor_compat() {
    local cand="$1" cur="$2" trusted slot fit hint fp
    need_cmd fdtget
    trusted="$(required_fps "$cand")"
    [ -n "$trusted" ] || die "anchor guard: candidate U-Boot DTB has no required=\"conf\" FIT key — it would boot unsigned FITs; refusing"
    for slot in A B; do
        fit="${BOOT_DIR}/fitImage-${slot}"
        [ -f "$fit" ] || { log "anchor guard: no ${fit}; slot ${slot} not checked"; continue; }
        hint="$(fit_signer "$fit" "conf-${slot}")"
        [ -n "$hint" ] || die "anchor guard: ${fit} conf-${slot} carries no signature; refusing"
        fp=""; [ -n "$cur" ] && fp="$(key_fp "$cur" "key-${hint}")"
        if [ -z "$fp" ]; then
            [ -n "$(key_fp "$cand" "key-${hint}")" ] \
                || die "anchor guard: candidate has no key '${hint}', which signed slot ${slot}; refusing"
            log "anchor guard: slot ${slot} signer '${hint}' not in the current anchor; checked by name only"
            continue
        fi
        printf '%s\n' "$trusted" | grep -qx "$fp" \
            || die "anchor guard: candidate U-Boot DTB does not trust key '${hint}' (${fp:0:16}…) that signed slot ${slot} — slot ${slot} would not boot; refusing"
        log "anchor guard: slot ${slot} signer '${hint}' (${fp:0:16}…) trusted by the candidate"
    done
}

# The anchor U-Boot currently verifies with: the FIP on the medium the board
# booted from (/chosen/edge,boot-source), else on the medium being written.
current_anchor() {
    local out="$1" src medium region
    medium="$(tr -d '\0' < /proc/device-tree/chosen/edge,boot-source 2>/dev/null || true)"
    case "$medium" in qspi|esd|emmc) ;; *) medium="${MODE:-}" ;; esac
    region="$(mktemp /tmp/rzv2l-cur.XXXXXX)"
    case "$medium" in
        qspi) cat "$MTD_FIP" > "$region" 2>/dev/null ;;
        esd)  dd if="$MMC_DEV" of="$region" iflag=skip_bytes,count_bytes skip=$((0x20000)) count=$((4 << 20)) status=none 2>/dev/null ;;
        emmc) dd if="${MMC_DEV}boot0" of="$region" iflag=skip_bytes skip=$((0x20000)) status=none 2>/dev/null ;;
    esac
    if fip_anchor "$region" "$out"; then rm -f "$region"; log "anchor guard: current anchor read from ${medium} FIP"; return 0; fi
    rm -f "$region"; log "anchor guard: no anchor found in the ${medium:-unknown} FIP"; return 1
}

# Refuse unless the FIP image $1 carries an anchor compatible with the slot FITs.
guard_fip_anchor() {
    local cand cur
    cand="$(mktemp /tmp/rzv2l-cand.XXXXXX)"; cur="$(mktemp /tmp/rzv2l-cur.XXXXXX)"
    fip_anchor "$1" "$cand" || { rm -f "$cand" "$cur"; die "anchor guard: no U-Boot DTB with FIT keys found in $1; refusing"; }
    current_anchor "$cur" || { rm -f "$cur"; cur=""; }
    check_anchor_compat "$cand" "${cur:-}"
    rm -f "$cand" ${cur:+"$cur"}
}

meta_get() { awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }

# Copy the part of the pair a run does not hold from the medium itself, so a
# restore always writes a complete pair. $1 = bl2|fip, $2 = output file.
snapshot_part() {
    local tag="$1" out="$2" size
    case "${tag}:${L_METHOD}" in
        bl2:flashcp) size="$(target_capacity "$L_BL2_TGT")" ;;
        bl2:dd)
            header_valid_on_medium || die "run ${RESTORE} holds no bl2 backup and the BL2 on ${L_BL2_TGT} has no valid header — restore a run that holds bl2, or re-run the update; refusing"
            size="$(od -An -tu4 -j"$L_BL2_OFF" -N4 "$L_BL2_TGT" | tr -d ' ')"
            case "$size" in ''|*[!0-9]*) die "cannot read the BL2 size word on ${L_BL2_TGT}; refusing" ;; esac
            [ "$size" -gt 0 ] && [ "$size" -le "$BL2_MAX" ] \
                || die "BL2 size word on ${L_BL2_TGT} is ${size}, outside 1..${BL2_MAX} — refusing"
            size=$(( L_HDR_LEN + size )) ;;
        fip:flashcp) size="$(target_capacity "$L_FIP_TGT")" ;;
        fip:dd) size=$(( ESD_ENV_OFFSET - L_FIP_OFF )) ;;
    esac
    case "$tag" in
        bl2) dd if="$L_BL2_TGT" of="$out" iflag=skip_bytes,count_bytes skip="$L_BL2_OFF" count="$size" status=none ;;
        fip) dd if="$L_FIP_TGT" of="$out" iflag=skip_bytes,count_bytes skip="$L_FIP_OFF" count="$size" status=none ;;
    esac
    log "restore: run holds no ${tag}; using the ${tag} currently on the medium ($size B)"
}

# Write back <run-dir>/{fip,bl2}.img as a pair, through the same ordering as an
# update. A run that holds only one part is completed from the medium.
do_restore() {
    local dir="${BACKUP_DIR}/${RESTORE}" tag meta img target offset size sha method
    local -a tags=()
    local bl2_src fip_src bl2_sha fip_sha fip_off=0 snap=""
    [ -d "$dir" ] || die "no backup run '${RESTORE}' in ${BACKUP_DIR}"
    for tag in fip bl2; do
        meta="${dir}/${tag}.meta"; img="${dir}/${tag}.img"
        if [ -f "$meta" ] && [ -f "$img" ]; then tags+=("$tag")
        elif [ -e "$meta" ] || [ -e "$img" ]; then die "backup run ${RESTORE} has ${tag}.img or ${tag}.meta but not both — backup corrupt, refusing"
        fi
    done
    [ "${#tags[@]}" -gt 0 ] || die "backup run ${RESTORE} holds no fip or bl2 backup"
    for tag in "${tags[@]}"; do
        meta="${dir}/${tag}.meta"; img="${dir}/${tag}.img"
        sha="$(meta_get "$meta" sha256)"
        [ "$(sha256sum "$img" | awk '{print $1}')" = "$sha" ] || die "${tag}.img hash != its meta — backup corrupt, refusing"
        target="$(meta_get "$meta" target)"; offset="$(meta_get "$meta" offset)"
        size="$(meta_get "$meta" size)"; method="$(meta_get "$meta" method)"
        case "${offset}${size}" in ''|*[!0-9]*) die "${tag}.meta offset/size not numeric — backup corrupt, refusing" ;; esac
        [ "$(stat -c%s "$img")" = "$size" ] || die "${tag}.img size != its meta"
        restore_location_ok "$tag" "$target" "$offset" "$method"
        case "$target" in
            /dev/mtd*)
                need_cmd flashcp
                if [ "$tag" = fip ]; then check_mtd_label "$target" "$MTD_FIP_LABEL"
                else check_mtd_label "$target" "$MTD_BL2_LABEL"; fi ;;
        esac
        check_fits "$img" "$target" "$offset" "$tag"
        log "restore $tag: ${img} -> $target @ $offset ($size B, $sha)"
    done
    case "$RESTORE_MODE" in esd|emmc) fip_off=$((0x20000)) ;; qspi) fip_off=0 ;; esac
    set_layout "$RESTORE_MODE" "$fip_off"
    for tag in "${tags[@]}"; do
        if [ "$tag" = fip ]; then guard_fip_anchor "${dir}/fip.img"; fi
    done
    if [ "$RESTORE_MODE" = esd ] && [ -f "${dir}/fip.img" ]; then
        check_esd_fip_end "$(stat -c%s "${dir}/fip.img")"
    fi
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Restore bootchain from backup run %s? [y/N]: ' "$RESTORE"
        read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    [ "$RESTORE_MODE" = emmc ] && boot0_writable "/sys/block/$(basename "${MMC_DEV}")boot0/force_ro"

    snap="$(mktemp -d /tmp/rzv2l-snap.XXXXXX)"
    if [ -f "${dir}/bl2.img" ]; then bl2_src="${dir}/bl2.img"; bl2_sha="$(meta_get "${dir}/bl2.meta" sha256)"
    else bl2_src="${snap}/bl2.img"; snapshot_part bl2 "$bl2_src"; bl2_sha="$(sha256sum "$bl2_src" | awk '{print $1}')"; fi
    if [ -f "${dir}/fip.img" ]; then fip_src="${dir}/fip.img"; fip_sha="$(meta_get "${dir}/fip.meta" sha256)"
    else fip_src="${snap}/fip.img"; snapshot_part fip "$fip_src"; fip_sha="$(sha256sum "$fip_src" | awk '{print $1}')"; fi
    pair_write "$bl2_src" "$bl2_sha" "$fip_src" "$fip_sha"
    rm -rf "$snap"
    finish restore
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --restore) RESTORE="$2"; shift 2 ;;
            --mode)    MODE="$2"; shift 2 ;;
            --variant) VARIANT="$2"; shift 2 ;;
            --yes)     ASSUME_YES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done

    [ "$(id -u)" -eq 0 ] || die "must run as root"
    need_cmd sha256sum; need_cmd dd; need_cmd awk; need_cmd stat; need_cmd date
    need_cmd flock; need_cmd od
    install -d "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    flock -n 9 || die "lock: another rzv2l-bootloader-update run holds ${LOCK_FILE} — refusing"
    if [ -n "$RESTORE" ]; then
        [ -z "$MODE" ] && [ -z "$VARIANT" ] || die "--restore takes no --mode/--variant"
        do_restore; return 0
    fi
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    case "$MODE" in qspi|esd|emmc) ;; *) die "--mode must be qspi|esd|emmc" ;; esac
    case "$VARIANT" in pmic|non-pmic) ;; *) die "--variant must be pmic|non-pmic" ;; esac
    check_variant

    # Artifact file names use "spi" and "mmc"; user-facing modes are "qspi" and "emmc".
    local bl2_prefix="bl2_bp_${MODE}"
    case "$MODE" in qspi) bl2_prefix="bl2_bp_spi" ;; emmc) bl2_prefix="bl2_bp_mmc" ;; esac
    local bl2 fip bl2_base fip_base
    bl2="$(pick_artifact "$bl2_prefix" "$VARIANT")" || true
    fip="$(pick_artifact "fip" "$VARIANT")" || true
    [ -n "${bl2:-}" ] || die "no BL2 artifact for mode=${MODE} variant=${VARIANT} in ${ROOT_DIR}"
    [ -n "${fip:-}" ] || die "no FIP artifact for variant=${VARIANT} in ${ROOT_DIR}"
    bl2_base="$(basename "$bl2")"; fip_base="$(basename "$fip")"

    local bl2_expected fip_expected
    bl2_expected="$(manifest_get "$bl2_base" "$MODE" "$VARIANT" 2)"
    fip_expected="$(manifest_get "$fip_base" "$MODE" "$VARIANT" 2)"
    [ -n "$bl2_expected" ] || die "BL2 $bl2_base not in manifest for mode=$MODE variant=$VARIANT"
    [ -n "$fip_expected" ] || die "FIP $fip_base not in manifest for mode=$MODE variant=$VARIANT"

    local bl2_hash fip_hash
    bl2_hash="$(sha256sum "$bl2" | awk '{print $1}')"
    fip_hash="$(sha256sum "$fip" | awk '{print $1}')"
    [ "$bl2_hash" = "$bl2_expected" ] || die "BL2 artifact hash != manifest ($bl2_base)"
    [ "$fip_hash" = "$fip_expected" ] || die "FIP artifact hash != manifest ($fip_base)"

    log "mode=${MODE} variant=${VARIANT}$([ "$DRY_RUN" -eq 1 ] && echo ' (dry-run)')"
    log "BL2: ${bl2_base} (${bl2_hash})"
    log "FIP: ${fip_base} (${fip_hash})"
    guard_fip_anchor "$fip"

    case "$MODE" in
        qspi)
            need_cmd flashcp; need_cmd mtd_debug
            [ -e "$MTD_BL2" ] || die "missing $MTD_BL2"
            [ -e "$MTD_FIP" ] || die "missing $MTD_FIP"
            check_mtd_label "$MTD_BL2" "$MTD_BL2_LABEL"
            check_mtd_label "$MTD_FIP" "$MTD_FIP_LABEL"
            local fip_off; fip_off="$(qspi_fip_offset)"
            log "QSPI FIP at absolute $(printf '%#x' "$QSPI_FIP_ADDR") = ${MTD_FIP} + $(printf '%#x' "$fip_off")"
            set_layout qspi "$fip_off"
            log "If interrupted: boot another medium (SW11) and --restore, or use the SCIF Flash Writer."
            ;;
        esd)
            need_cmd blockdev
            [ -b "$MMC_DEV" ] || die "missing block device $MMC_DEV"
            check_mmc_medium SD
            check_sd_layout
            # bl2_bp_esd = 7 x 512-byte boot-parameter copies + BL2 code, placed
            # at sector 1 (0x200); sector 0 is the MBR. The code lands at 0x1000.
            set_layout esd $((0x20000))
            check_esd_fip_end "$(stat -c%s "$fip")"
            log "If interrupted: boot another medium (SW11) and --restore, or rewrite the card on a host (the Flash Writer cannot write SD)."
            ;;
        emmc)
            need_cmd blockdev
            [ -b "$MMC_DEV" ] || die "missing block device $MMC_DEV"
            [ -e "${MMC_DEV}boot0" ] || die "missing ${MMC_DEV}boot0 (not an eMMC, or boot partition absent)"
            check_mmc_medium MMC
            check_emmc_boot_config
            set_layout emmc $((0x20000))
            log "If interrupted: U-Boot of another medium (mmc write to boot0), or the SCIF Flash Writer."
            ;;
    esac
    check_fits "$fip" "$L_FIP_TGT" "$L_FIP_OFF" fip
    check_fits "$bl2" "$L_BL2_TGT" "$L_BL2_OFF" bl2
    header_valid "$bl2" || die "BL2 artifact ${bl2_base} has no valid boot-parameter header (AA55 at 0x1FE) — refusing"

    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Proceed with bootchain update (mode=%s variant=%s)? [y/N]: ' "$MODE" "$VARIANT"
        read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi

    [ "$MODE" = emmc ] && boot0_writable "/sys/block/$(basename "${MMC_DEV}")boot0/force_ro"
    pair_write "$bl2" "$bl2_hash" "$fip" "$fip_hash"

    finish update
}

main "$@"
