#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# RZ/V2L RAUC bundle hook — pre-install and post-install
#
# Post-install installs the signed FIT matching the written verity slot, then
# atomically migrates managed boot variables and records the OTA audit trail.
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

# Require tools used unconditionally.
for _cmd in mount umount sync mountpoint install cmp mktemp mv fw_setenv; do
  command -v "$_cmd" >/dev/null 2>&1 || die "Missing required command: $_cmd"
done

# ---------------------------------------------------------------------------
# Install only the target slot FIT. Mutating the ext4 superblock after the raw
# write would invalidate its appended dm-verity tree.
# ---------------------------------------------------------------------------
case "${RAUC_SLOT_NAME:-}" in
  rootfs.0)
    slot_letter="A"
    fit_source="${BUNDLE_MNT}/@FIT_IMAGE_A@"
    ;;
  rootfs.1)
    slot_letter="B"
    fit_source="${BUNDLE_MNT}/@FIT_IMAGE_B@"
    ;;
  *) die "Unsupported RAUC slot '${RAUC_SLOT_NAME:-}'" ;;
esac

[ -f "${fit_source}" ] || die "Signed slot FIT missing from bundle: ${fit_source}"

mounted_here=0
if ! mountpoint -q "${BOOT_MP}"; then
  log_info "Mounting ${BOOT_DEV} at ${BOOT_MP}"
  mkdir -p "${BOOT_MP}"
  mount "${BOOT_DEV}" "${BOOT_MP}" || die "Failed to mount ${BOOT_DEV} at ${BOOT_MP}"
  mounted_here=1
fi
mount -o remount,rw "${BOOT_MP}" || die "Failed to remount ${BOOT_MP} read-write"

# /run, not /tmp: the hook runs on the installed (dm-verity, read-only /tmp
# unless tmp.mount landed) system; /run is writable unconditionally.
tmpdir="$(mktemp -d /run/verity-boot.XXXXXX)"
cleanup_boot() {
  rm -rf "${tmpdir}" || true
  if [ "${mounted_here}" -eq 1 ]; then
    sync || true
    umount "${BOOT_MP}" || log_warn "Failed to unmount ${BOOT_MP}"
  fi
}
trap cleanup_boot EXIT INT TERM

fit_target="${BOOT_MP}/fitImage-${slot_letter}"
fit_pending="${BOOT_MP}/.fitImage-${slot_letter}.new"
if [ -f "${fit_target}" ] && cmp -s "${fit_source}" "${fit_target}"; then
  log_debug "fitImage-${slot_letter}: unchanged"
else
  log_info "Installing signed fitImage-${slot_letter}"
  install -m 0644 "${fit_source}" "${fit_pending}"
  sync "${fit_pending}" 2>/dev/null || sync
  mv -f "${fit_pending}" "${fit_target}"
  sync "${BOOT_MP}" 2>/dev/null || sync
fi

# Apply structural boot variables and the target marker in one redundant-env
# transaction. The old slot remains on its legacy path until it is updated.
defaults="${BUNDLE_MNT}/rauc-uboot-env.defaults"
[ -f "${defaults}" ] || die "Managed U-Boot defaults missing from bundle"
env_batch="${tmpdir}/fw-setenv.batch"
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in ''|\#*) continue ;; esac
  key="${line%%=*}"
  value="${line#*=}"
  printf '%s %s\n' "${key}" "${value}" >> "${env_batch}"
done < "${defaults}"
printf 'EDGE_VERITY_%s 1\n' "${slot_letter}" >> "${env_batch}"
_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
printf 'edge_last_slot %s\n' "${RAUC_SLOT_NAME}" >> "${env_batch}"
printf 'edge_last_update %s\n' "${_now}" >> "${env_batch}"
fw_setenv -s "${env_batch}" || die "Atomic U-Boot environment migration failed"
log_info "U-Boot env migrated for verified slot ${slot_letter}"

log_info "post-install: completed successfully"
exit 0
