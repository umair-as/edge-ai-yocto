#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Guarded, operator-run Raspberry Pi 5 FAT boot-file updater. The FAT-file
# sibling of rzv2l-bootloader-update: same guard chain, hash manifest, and
# backup/--restore, writing files to the shared /boot partition instead of raw
# flash offsets. It is never wired into RAUC and never runs unattended.
#
# The files are single-copy on the shared FAT /boot (no A/B redundancy):
#   kernel_2712.img      U-Boot, loaded by the firmware as the kernel
#   bcm2712-rpi-5-b.dtb  firmware control FDT and the FIT trust anchor; it must
#                        carry the same FIT signing key as the installed slot
#                        FITs, or U-Boot cannot verify either slot after the swap
#   config.txt           read by the firmware before the kernel
# RAUC rootfs A/B does not cover /boot, so a bad write is not rolled back by a
# slot switch. Every check fails before the first write, the current files are
# backed up first, and each write is an atomic rename verified by read-back.
# --restore <run-id> writes a backup back through the same guards.
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR=${ROOT_DIR:-/usr/share/rpi-boot}
MANIFEST=${MANIFEST:-${ROOT_DIR}/manifest.tsv}
BOOT_MP=${BOOT_MP:-/boot}
# Must survive a reboot: /var/lib is a volatile overlay on the verity rootfs.
BACKUP_DIR=${BACKUP_DIR:-/data/rpi-boot/backup}

# config.txt and the board DTB are read by the firmware, then kernel_2712.img
# (U-Boot) is executed. Written in that order so the execution entry changes
# last: an interruption leaves the prior U-Boot runnable.
ARTIFACTS=(config.txt bcm2712-rpi-5-b.dtb kernel_2712.img)

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

log() { printf '[edge-rpi-bootfiles-update] %s\n' "$*"; }
die() { printf '[edge-rpi-bootfiles-update][ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

finish() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$1 dry-run complete: ${PLANNED} file(s) would be written; nothing written."
    elif [ "$WRITES" -eq 0 ]; then
        log "$1 complete: boot files already current; nothing written, no reboot needed."
    else
        log "$1 complete: ${WRITES} file(s) written. Reboot for the new boot files to take effect."
    fi
}

usage() {
    cat <<'EOF'
Usage:
  edge-rpi-bootfiles-update [--yes] [--dry-run]
  edge-rpi-bootfiles-update --restore <run-id> [--yes] [--dry-run]

Writes the staged U-Boot (kernel_2712.img), board DTB and config.txt to the FAT
/boot partition after verifying them against the manifest, backing up the
current files, and reading each back to confirm. Reboot after a successful run.

Options:
  --yes               Non-interactive confirmation
  --restore <run-id>  Write back the backup of an earlier run (ls BACKUP_DIR)
  --dry-run           Print planned actions only; write nothing
  --help              Show this help

Environment overrides:
  ROOT_DIR=/usr/share/rpi-boot  MANIFEST=$ROOT_DIR/manifest.tsv
  BOOT_MP=/boot  BACKUP_DIR=/data/rpi-boot/backup

Recovery: a failed write is repaired with --restore <run-id>, or by rewriting
/boot from a host (see docs/dev/bootchain/raspberrypi5.md).
EOF
}

# manifest columns: artifact  sha256  size  boot_target
manifest_col() {
    awk -F'\t' -v n="$1" -v c="$2" 'NR==1{next} $1==n {print $c; exit}' "$MANIFEST"
}
sha_of()     { sha256sum "$1" | awk '{print $1}'; }
meta_get()   { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }
free_bytes() { df -Pk "$BOOT_MP" 2>/dev/null | awk 'NR==2{print $4*1024}'; }

# /boot must be the mounted, writable FAT partition — never a bare directory.
check_boot() {
    local line
    line=$(findmnt -no FSTYPE,OPTIONS "$BOOT_MP" 2>/dev/null) || die "$BOOT_MP is not a mount point"
    case "$line" in vfat*) ;; *) die "$BOOT_MP is not a FAT filesystem: $line" ;; esac
    case ",${line#* }," in *,rw,*) ;; *) die "$BOOT_MP is not mounted read-write: $line" ;; esac
}

# Save the current /boot/<target> (or record its absence) for --restore.
backup_file() {
    local target="$1" dst="${BOOT_MP}/$1"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN back up ${dst} -> ${RUN_DIR}/${target}"; return 0; }
    install -d -m 0700 "$RUN_DIR"
    if [ -f "$dst" ]; then
        cp -a "$dst" "${RUN_DIR}/${target}"; sync
        printf 'target\t%s\nsize\t%s\nsha256\t%s\npresent\t1\n' \
            "$target" "$(stat -c%s "${RUN_DIR}/${target}")" "$(sha_of "${RUN_DIR}/${target}")" \
            > "${RUN_DIR}/${target}.meta"
    else
        printf 'target\t%s\npresent\t0\n' "$target" > "${RUN_DIR}/${target}.meta"
    fi
    sync
    log "backed up ${target} -> ${RUN_DIR}/"
}

# Skip if current, check space, back up, atomic write, read back.
write_verify() {
    local src="$1" target="$2" expected="$3" dst="${BOOT_MP}/$2" size cur avail tmp read_hash
    size="$(stat -c%s "$src")"
    cur=""; [ -f "$dst" ] && cur="$(sha_of "$dst")"
    if [ "$cur" = "$expected" ]; then
        log "${target} already current on $BOOT_MP — skipping"; return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN would write ${target} (${size} B) to ${dst}"; PLANNED=$((PLANNED+1)); return 0
    fi
    avail="$(free_bytes)"
    [ -n "$avail" ] || die "cannot read free space on $BOOT_MP"
    [ "$size" -le "$avail" ] || die "${target} (${size} B) exceeds free space on $BOOT_MP (${avail} B)"
    backup_file "$target"
    tmp="${BOOT_MP}/.${target}.new"
    rm -f "$tmp"
    cp "$src" "$tmp"; sync
    # Dropped page cache: the hashes come from the FAT medium, not from the
    # pages just written. A bad copy is refused before it replaces the file.
    echo 3 > /proc/sys/vm/drop_caches
    [ "$(sha_of "$tmp")" = "$expected" ] \
        || { rm -f "$tmp"; die "copy of ${target} on $BOOT_MP failed verification — current file left in place"; }
    mv -f "$tmp" "$dst"; sync
    echo 3 > /proc/sys/vm/drop_caches
    read_hash="$(sha_of "$dst")"
    [ "$read_hash" = "$expected" ] \
        || die "readback mismatch for ${target} (wrote but verify failed — DO NOT REBOOT; re-run or --restore)"
    log "${target} written and verified"
    WRITES=$((WRITES+1))
}

do_update() {
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    check_boot
    local a src exp
    for a in "${ARTIFACTS[@]}"; do          # verify every artifact BEFORE any write
        src="${ROOT_DIR}/${a}"
        [ -f "$src" ] || die "staged artifact missing: $src"
        exp="$(manifest_col "$a" 2)"
        [ -n "$exp" ] || die "$a not in manifest"
        [ "$(sha_of "$src")" = "$exp" ] || die "$a artifact hash != manifest"
    done
    log "boot-file update for ${BOOT_MP}$([ "$DRY_RUN" -eq 1 ] && echo ' (dry-run)')"
    for a in "${ARTIFACTS[@]}"; do log "  $a ($(manifest_col "$a" 2))"; done
    log "The board DTB carries the FIT signing key — only apply boot files built with the key the installed slot FITs were signed with."
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Proceed with the %s file update? [y/N]: ' "$BOOT_MP"; read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    for a in "${ARTIFACTS[@]}"; do
        write_verify "${ROOT_DIR}/${a}" "$a" "$(manifest_col "$a" 2)"
    done
    finish update
}

do_restore() {
    local dir="${BACKUP_DIR}/${RESTORE}" a meta
    [ -d "$dir" ] || die "no backup run '${RESTORE}' in ${BACKUP_DIR}"
    check_boot
    for a in "${ARTIFACTS[@]}"; do          # pre-verify the backup
        meta="${dir}/${a}.meta"; [ -f "$meta" ] || continue
        if [ "$(meta_get "$meta" present)" = "1" ]; then
            [ -f "${dir}/${a}" ] || die "backup ${RESTORE} lacks ${a}"
            [ "$(sha_of "${dir}/${a}")" = "$(meta_get "$meta" sha256)" ] || die "${a} backup hash != meta — corrupt"
        fi
    done
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Restore %s files from backup run %s? [y/N]: ' "$BOOT_MP" "$RESTORE"; read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    for a in "${ARTIFACTS[@]}"; do
        meta="${dir}/${a}.meta"; [ -f "$meta" ] || continue
        if [ "$(meta_get "$meta" present)" = "1" ]; then
            write_verify "${dir}/${a}" "$a" "$(meta_get "$meta" sha256)"
        elif [ "$DRY_RUN" -eq 0 ] && [ -f "${BOOT_MP}/${a}" ]; then
            log "restore: ${a} was absent in the backup; removing current"
            backup_file "$a"
            rm -f "${BOOT_MP}/${a}"; sync; WRITES=$((WRITES+1))
        fi
    done
    finish restore
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --restore) RESTORE="${2:-}"; shift 2 ;;
            --yes)     ASSUME_YES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    need_cmd sha256sum; need_cmd awk; need_cmd stat; need_cmd findmnt; need_cmd df
    if [ -n "$RESTORE" ]; then do_restore; else do_update; fi
}

main "$@"
