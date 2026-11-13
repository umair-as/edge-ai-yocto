#!/bin/bash
# SPDX-License-Identifier: MIT
#
# uefi-uki RAUC bundle hook (ADR-0016 §6, custom backend), rootfs slot hooks.
#
# The UKI carries the slot's dm-verity root hash, so a rootfs written without
# its UKI cannot mount. RAUC has marked the target slot bad before the write
# and activates it after this hook, through the custom backend; the hook only
# replaces the target slot's UKI on the ESP, keeping its entry name.
#
#   pre-install   the running system's backend can read both slot entries
#   post-install  the bundle's UKI for the target slot replaces the ESP copy
set -euo pipefail

readonly BACKEND=@SDBOOT_BACKEND@
readonly BUNDLE_MNT=${RAUC_BUNDLE_MOUNT_POINT:-/run/rauc/mnt/bundle}

log() { printf '[bundle-hook] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

hook=${1:-}
case "$hook" in
    slot-pre-install) hook=pre-install ;;
    slot-post-install) hook=post-install ;;
esac

case "${RAUC_SLOT_BOOTNAME:-}" in
    A) uki=$BUNDLE_MNT/@UKI_IMAGE_A@ ;;
    B) uki=$BUNDLE_MNT/@UKI_IMAGE_B@ ;;
    *) die "slot '${RAUC_SLOT_NAME:-?}' has bootname '${RAUC_SLOT_BOOTNAME:-}', expected A or B" ;;
esac

[[ -x $BACKEND ]] || die "$BACKEND missing: the running image does not use the custom backend; re-image instead"

case "$hook" in
    pre-install)
        [[ -f $uki ]] || die "bundle has no UKI for slot $RAUC_SLOT_BOOTNAME: $uki"
        primary=$("$BACKEND" get-primary) || die "slot entries on the ESP are not readable"
        state=$("$BACKEND" get-state "$RAUC_SLOT_BOOTNAME") || die "no ESP entry for slot $RAUC_SLOT_BOOTNAME"
        log "pre-install: slot $RAUC_SLOT_BOOTNAME ($state), primary $primary"
        ;;
    post-install)
        "$BACKEND" install-uki "$RAUC_SLOT_BOOTNAME" "$uki"
        log "post-install: slot $RAUC_SLOT_BOOTNAME UKI installed"
        ;;
    *) die "unexpected hook '${1:-}'" ;;
esac
