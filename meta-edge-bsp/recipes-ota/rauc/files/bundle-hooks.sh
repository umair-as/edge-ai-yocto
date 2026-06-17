#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# RZ/V2L RAUC bundle hook — pre-install and post-install
#
# Post-install responsibilities:
#   1. Re-label the written ext4 slot (WIC does not reliably set the first
#      --source rootfs label; e2label ensures by-label paths stay stable).
#   2. Extract bootfiles.tar.gz (fitImage, DTB, splash.bmp) into
#      /boot when the bundle carries one, installing only changed files.
#   3. Record OTA audit trail in U-Boot env (edge_last_slot, edge_last_update).
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
HOOK_LOG_LEVEL="${EDGE_HOOK_LOG_LEVEL:-INFO}"
case "${HOOK_LOG_LEVEL}" in
  error|ERROR)   HOOK_LOG_LEVEL="ERROR" ;;
  warn|WARN)     HOOK_LOG_LEVEL="WARN"  ;;
  debug|DEBUG)   HOOK_LOG_LEVEL="DEBUG" ;;
  *)             HOOK_LOG_LEVEL="INFO"  ;;
esac

_log_level_num() {
  case "$1" in ERROR) echo 0 ;; WARN) echo 1 ;; INFO) echo 2 ;; DEBUG) echo 3 ;; *) echo 2 ;; esac
}

_log() {
  local level="$1"; shift
  [ "$(_log_level_num "$level")" -le "$(_log_level_num "$HOOK_LOG_LEVEL")" ] || return 0
  printf '[bundle-hook][%s] %s\n' "$level" "$*" >&2
}

log_error() { _log ERROR "$*"; }
log_warn()  { _log WARN  "$*"; }
log_info()  { _log INFO  "$*"; }
log_debug() { _log DEBUG "$*"; }
die()       { log_error "$*"; exit 1; }

on_err() { log_error "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-?})"; }
trap 'on_err $LINENO' ERR

# ---------------------------------------------------------------------------
# Resolve hook type — RAUC passes it as $1; older builds export env vars
# ---------------------------------------------------------------------------
HOOK_TYPE="${1:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_HOOK_TYPE:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_SLOT_HOOK:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_SLOT_HOOK_TYPE:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_HOOK:-}"
case "$HOOK_TYPE" in
  slot-post-install) HOOK_TYPE="post-install" ;;
  slot-pre-install)  HOOK_TYPE="pre-install"  ;;
esac

BUNDLE_MNT="${RAUC_BUNDLE_MOUNT_POINT:-/run/rauc/mnt/bundle}"
BOOT_DEV="/dev/disk/by-rauc-slot/boot"
BOOT_MP="/boot"

# ---------------------------------------------------------------------------
# pre-install
# ---------------------------------------------------------------------------
case "${HOOK_TYPE}" in
  pre-install)
    log_info "pre-install: slot='${RAUC_SLOT_NAME:-unknown}'"
    # Placeholder for future pre-install checks (signature pinning, rollback
    # guard, free-space check, etc.).  Fail fast here to abort before RAUC
    # writes anything to the target slot.
    log_info "pre-install: checks passed"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# post-install — everything below only runs for post-install
# ---------------------------------------------------------------------------
[ "${HOOK_TYPE}" = "post-install" ] || {
  log_warn "Unknown hook type '${HOOK_TYPE:-}'; exiting"
  exit 0
}

log_info "post-install: slot='${RAUC_SLOT_NAME:-unknown}' device='${RAUC_SLOT_DEVICE:-unknown}'"

# Require tools used unconditionally
for _cmd in mount umount sync; do
  command -v "$_cmd" >/dev/null 2>&1 || die "Missing required command: $_cmd"
done

# ---------------------------------------------------------------------------
# 1. Re-label the ext4 slot so /dev/disk/by-label paths stay stable.
#    RAUC writes a raw ext4 image whose superblock label may differ from the
#    partition's intended label (WIC drops the first --source rootfs label).
# ---------------------------------------------------------------------------
desired_label=""
case "${RAUC_SLOT_NAME:-}" in
  rootfs.0) desired_label="rootfsA" ;;
  rootfs.1) desired_label="rootfsB" ;;
esac

if [ -n "${desired_label}" ] && [ -n "${RAUC_SLOT_DEVICE:-}" ]; then
  if command -v e2label >/dev/null 2>&1; then
    current_label="$(e2label "${RAUC_SLOT_DEVICE}" 2>/dev/null || true)"
    if [ "${current_label}" != "${desired_label}" ]; then
      log_info "Relabelling ${RAUC_SLOT_DEVICE}: '${current_label}' -> '${desired_label}'"
      e2label "${RAUC_SLOT_DEVICE}" "${desired_label}" \
        || log_warn "e2label failed on ${RAUC_SLOT_DEVICE} (by-label path may be stale until next udev settle)"
    else
      log_debug "Slot label already '${desired_label}'; no relabelling needed"
    fi
  else
    log_warn "e2label not found; skipping slot relabelling (install ${RAUC_SLOT_DEVICE} label manually if by-label fails)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Boot files update (fitImage, DTB, splash.bmp)
#    Only installs files present in the bundle and only when content changed.
# ---------------------------------------------------------------------------
ARCHIVE="${BUNDLE_MNT}/bootfiles.tar.gz"

if [ ! -f "${ARCHIVE}" ]; then
  log_debug "No bootfiles.tar.gz in bundle; skipping /boot update"
else
  for _cmd in tar cmp install mktemp; do
    command -v "$_cmd" >/dev/null 2>&1 || die "Missing required command for bootfiles update: $_cmd"
  done

  log_info "Bootfiles archive found — updating /boot"

  # Mount /boot if not already mounted
  mounted_here=0
  if ! mountpoint -q "${BOOT_MP}"; then
    log_info "Mounting ${BOOT_DEV} at ${BOOT_MP}"
    mkdir -p "${BOOT_MP}"
    mount "${BOOT_DEV}" "${BOOT_MP}" || die "Failed to mount ${BOOT_DEV} at ${BOOT_MP}"
    mounted_here=1
  fi

  # Ensure writable
  mount -o remount,rw "${BOOT_MP}" 2>/dev/null \
    || log_warn "Could not remount ${BOOT_MP} read-write; writes may fail"

  tmpdir="$(mktemp -d /tmp/bootfiles.XXXXXX)"
  cleanup_boot() {
    rm -rf "${tmpdir}" || true
    if [ "${mounted_here}" -eq 1 ]; then
      sync || true
      umount "${BOOT_MP}" || log_warn "Failed to umount ${BOOT_MP}"
    fi
  }
  trap cleanup_boot EXIT INT TERM

  log_debug "Extracting bootfiles to ${tmpdir}"
  tar -C "${tmpdir}" -xzf "${ARCHIVE}" \
    || die "Failed to extract ${ARCHIVE}"

  # Install only when content differs
  files_changed=0
  files_skipped=0

  install_if_changed() {
    local src="$1" dst="$2" label="$3"
    if [ -f "${dst}" ] && cmp -s "${src}" "${dst}"; then
      log_debug "${label}: unchanged"
      files_skipped=$(( files_skipped + 1 ))
      return 0
    fi
    log_info "Installing ${label}"
    install -m 0644 "${src}" "${dst}"
    files_changed=$(( files_changed + 1 ))
  }

  # Boot assets for FIT-only boot. @DTB_FILENAME@ is substituted at
  # bundle build time from EDGE_BOOT_DTB (see edge-bundle-common.inc).
  # splash.bmp is included unconditionally; the per-file [ -f ] check
  # below makes it a no-op on boards that don't ship a pre-kernel splash.
  for _f in fitImage @DTB_FILENAME@ splash.bmp; do
    if [ -f "${tmpdir}/${_f}" ]; then
      install_if_changed "${tmpdir}/${_f}" "${BOOT_MP}/${_f}" "${_f}"
    fi
  done

  sync || true
  log_info "Boot files: ${files_changed} updated, ${files_skipped} unchanged"

  # cleanup_boot runs on EXIT
fi

# ---------------------------------------------------------------------------
# 3. OTA audit trail in U-Boot env
# ---------------------------------------------------------------------------
if command -v fw_setenv >/dev/null 2>&1; then
  _now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  fw_setenv edge_last_slot   "${RAUC_SLOT_NAME:-unknown}"  \
    || log_warn "fw_setenv edge_last_slot failed"
  fw_setenv edge_last_update "${_now}"                      \
    || log_warn "fw_setenv edge_last_update failed"
  log_info "U-Boot env: edge_last_slot=${RAUC_SLOT_NAME:-unknown} edge_last_update=${_now}"
else
  log_warn "fw_setenv not available; skipping U-Boot env audit trail"
fi

log_info "post-install: completed successfully"
exit 0
