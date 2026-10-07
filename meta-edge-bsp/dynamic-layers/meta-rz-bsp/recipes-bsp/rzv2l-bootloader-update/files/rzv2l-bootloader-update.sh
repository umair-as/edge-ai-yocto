#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Guarded RZ/V2L bootchain updater (BL2 + FIP).
#
# The RZ/V2L bootchain (BL2 at the ROM-expected offset, then FIP = TF-A BL31 +
# OP-TEE BL32 + U-Boot BL33) lives in single-copy storage with no A/B
# redundancy: QSPI (mtd "bl2"/"fip"), eSD raw offsets, or the eMMC boot
# partition. There is no runtime rollback once written, so every check that can
# fail the operation does so BEFORE the first byte is written, and a copy of the
# current content is saved first. A failed or interrupted write is recovered
# out-of-band with the Renesas SCIF Flash Writer over serial.
#
# Guard chain, in order:
#   1. root, required --mode/--variant, required tools present; --variant
#      matches the detected PMIC (RAA215300 present => pmic)
#   2. staged artifact SHA-256 == manifest  (artifact integrity)
#   3. QSPI only: /proc/mtd labels are the expected "bl2"/"fip"  (right layout)
#   4. every target can hold offset+size, all checked before any write
#   5. skip if the target already holds this exact content        (no needless
#      flash wear / brick window)
#   6. back up the current content to /data/.../<run-id>/         (local rollback,
#      survives reboot; whole partition for QSPI, since flashcp erases whole
#      4 KiB blocks past the end of a shorter image)
#   7. write, sync, read back, re-hash                            (write verify)
#
# --restore <run-id> writes a run's backup back through the same guards (label,
# capacity, skip-if-current, backup-first, readback).
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
# 1 = accept a --variant that disagrees with the detected PMIC.
ALLOW_VARIANT_MISMATCH=${ALLOW_VARIANT_MISMATCH:-0}

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

Recovery: a failed/interrupted write is repaired with the Renesas SCIF Flash
Writer over the serial console (see docs/dev/bootchain/rzv2l.md).
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

# Skip if already current, back up, write, read back. check_fits ran already.
write_verify() {
    local src="$1" target="$2" offset="$3" expected="$4" tag="$5" method="$6"
    local size current read_hash
    size="$(stat -c%s "$src")"
    check_fits "$src" "$target" "$offset" "$tag"

    current="$(readback_hash "$target" "$offset" "$size")"
    if [ "$current" = "$expected" ]; then
        log "$tag already current on $target (hash match) — skipping write"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN would write $tag ($size B) to $target @ offset $offset via $method"
        PLANNED=$((PLANNED + 1))
        return 0
    fi

    backup_region "$target" "$offset" "$size" "$tag" "$method"

    case "$method" in
        flashcp)
            if [ "$offset" -eq 0 ]; then
                flashcp -v "$src" "$target"
            else
                # Keep the partition's current bytes before the offset, append
                # the artifact, and write that from the partition start.
                local img; img="$(mktemp /tmp/rzv2l-bl.XXXXXX)"
                head -c "$offset" "$target" > "$img"
                cat "$src" >> "$img"
                flashcp -v "$img" "$target"
                rm -f "$img"
            fi ;;
        dd)      dd if="$src" of="$target" oflag=seek_bytes seek="$offset" bs=64K conv=fsync,notrunc status=none ;;
        *)       die "internal: unknown write method $method" ;;
    esac
    sync

    read_hash="$(readback_hash "$target" "$offset" "$size")"
    [ "$read_hash" = "$expected" ] || die "readback hash mismatch for $tag on $target @ offset $offset (wrote but verify failed — DO NOT REBOOT; re-run or recover via Flash Writer)"
    log "$tag written and verified on $target"
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

# Make eMMC boot0 writable for the writes that follow; the EXIT trap restores
# read-only on every exit path, including a refusal or failed readback.
boot0_writable() {
    local ro="$1"
    [ "$DRY_RUN" -eq 0 ] && [ -e "$ro" ] || return 0
    trap 'echo 1 > "'"$ro"'" 2>/dev/null || true' EXIT
    echo 0 > "$ro"
}

# A restore writes only to the fixed bootchain locations, never to a target
# taken from the backup's .meta: <tag> <target> <offset> <method>.
restore_location_ok() {
    local tag="$1" target="$2" offset="$3" method="$4"
    case "${tag} ${target} ${offset} ${method}" in
        "fip ${MTD_FIP} 0 flashcp"|"bl2 ${MTD_BL2} 0 flashcp") ;;
        "fip ${MMC_DEV} $((0x20000)) dd"|"bl2 ${MMC_DEV} $((0x200)) dd") check_mmc_medium SD ;;
        "fip ${MMC_DEV}boot0 $((0x20000)) dd"|"bl2 ${MMC_DEV}boot0 $((0x200)) dd") check_mmc_medium MMC ;;
        *) die "backup ${tag}.meta names ${target} @ ${offset} via ${method}, not a bootchain location — refusing" ;;
    esac
}

meta_get() { awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }

# Write back <run-dir>/{fip,bl2}.img to where they came from, FIP first. A run
# holds only the regions its update wrote; a region skipped as already current
# has no backup and is not touched.
do_restore() {
    local dir="${BACKUP_DIR}/${RESTORE}" tag meta img target offset size sha method
    local -a tags=()
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
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Restore bootchain from backup run %s? [y/N]: ' "$RESTORE"
        read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    local ro_sysfs=""
    for tag in "${tags[@]}"; do
        case "$(meta_get "${dir}/${tag}.meta" target)" in
            *boot0) ro_sysfs="/sys/block/$(basename "$(meta_get "${dir}/${tag}.meta" target)")/force_ro" ;;
        esac
    done
    [ -n "$ro_sysfs" ] && boot0_writable "$ro_sysfs"
    for tag in "${tags[@]}"; do
        meta="${dir}/${tag}.meta"
        write_verify "${dir}/${tag}.img" "$(meta_get "$meta" target)" "$(meta_get "$meta" offset)" \
            "$(meta_get "$meta" sha256)" "$tag" "$(meta_get "$meta" method)"
    done
    [ "$DRY_RUN" -eq 0 ] && [ -n "$ro_sysfs" ] && [ -e "$ro_sysfs" ] && echo 1 > "$ro_sysfs" || true
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
    log "A failed write is recoverable only via the SCIF Flash Writer over serial."

    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Proceed with bootchain update (mode=%s variant=%s)? [y/N]: ' "$MODE" "$VARIANT"
        read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi

    case "$MODE" in
        qspi)
            need_cmd flashcp
            [ -e "$MTD_BL2" ] || die "missing $MTD_BL2"
            [ -e "$MTD_FIP" ] || die "missing $MTD_FIP"
            check_mtd_label "$MTD_BL2" "$MTD_BL2_LABEL"
            check_mtd_label "$MTD_FIP" "$MTD_FIP_LABEL"
            # FIP (larger) first, BL2 last: the ROM entry (BL2) is the last thing
            # changed, so an interruption before BL2 leaves the ROM loading the
            # prior BL2 against a new FIP rather than a half-written BL2.
            local fip_off; fip_off="$(qspi_fip_offset)"
            log "QSPI FIP at absolute $(printf '%#x' "$QSPI_FIP_ADDR") = ${MTD_FIP} + $(printf '%#x' "$fip_off")"
            check_fits "$fip" "$MTD_FIP" "$fip_off" fip; check_fits "$bl2" "$MTD_BL2" 0 bl2
            write_verify "$fip" "$MTD_FIP" "$fip_off" "$fip_hash" "fip" flashcp
            write_verify "$bl2" "$MTD_BL2" 0 "$bl2_hash" "bl2" flashcp
            ;;
        esd)
            need_cmd blockdev
            [ -b "$MMC_DEV" ] || die "missing block device $MMC_DEV"
            check_mmc_medium SD
            # bl2_bp_esd carries the 3584-byte boot-parameter header followed by
            # BL2 code; the WIC rawcopy places it at sector 1 (0x200), leaving the
            # MBR at sector 0 untouched. BL2 code then lands at 0x1000 where the
            # ROM expects it. Writing at 0x1000 would misplace the header — use
            # 0x200. FIP at 0x20000.
            check_fits "$fip" "$MMC_DEV" $((0x20000)) fip; check_fits "$bl2" "$MMC_DEV" $((0x200)) bl2
            write_verify "$fip" "$MMC_DEV" $((0x20000)) "$fip_hash" "fip" dd
            write_verify "$bl2" "$MMC_DEV" $((0x200))   "$bl2_hash" "bl2" dd
            ;;
        emmc)
            need_cmd blockdev
            [ -b "$MMC_DEV" ] || die "missing block device $MMC_DEV"
            [ -e "${MMC_DEV}boot0" ] || die "missing ${MMC_DEV}boot0 (not an eMMC, or boot partition absent)"
            local ro_sysfs
            ro_sysfs="/sys/block/$(basename "${MMC_DEV}")boot0/force_ro"
            check_mmc_medium MMC
            check_fits "$fip" "${MMC_DEV}boot0" $((0x20000)) fip; check_fits "$bl2" "${MMC_DEV}boot0" $((0x200)) bl2
            boot0_writable "$ro_sysfs"
            write_verify "$fip" "${MMC_DEV}boot0" $((0x20000)) "$fip_hash" "fip" dd
            write_verify "$bl2" "${MMC_DEV}boot0" $((0x200))   "$bl2_hash" "bl2" dd
            [ "$DRY_RUN" -eq 0 ] && [ -e "$ro_sysfs" ] && echo 1 > "$ro_sysfs" || true
            ;;
    esac

    finish update
}

main "$@"
