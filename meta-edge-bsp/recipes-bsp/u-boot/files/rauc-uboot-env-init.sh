#!/usr/bin/env bash
set -Eeuo pipefail

# Versioned idempotency marker so env migrations can be rolled out safely.
STAMP="/boot/.rauc-uboot-env-initialized-v3-fit-only"
ENV_DEFAULTS="/etc/rauc-uboot-env.defaults"

log() { echo "[rauc-uboot-env-init] $*"; }

# Idempotency guard
if [ -f "$STAMP" ]; then
    exit 0
fi

if ! command -v fw_printenv >/dev/null 2>&1 || ! command -v fw_setenv >/dev/null 2>&1; then
    log "fw_printenv/fw_setenv not available; skipping"
    exit 0
fi

# Probe current env. Invalid CRC is expected on first boot after a fresh flash.
if ! fw_printenv >/dev/null 2>&1; then
    log "U-Boot env CRC invalid (expected on first boot); will initialize RAUC vars"
fi

_setenv() {
    local key="$1" val="$2"
    if fw_setenv "$key" "$val"; then
        log "Set ${key}=${val}"
    else
        log "WARNING: fw_setenv ${key} failed (exit $?) — U-Boot env not writable"
        log "         Check: /boot partition --align 4096 in WKS and FIP in SPI NOR"
        return 1
    fi
}

env_ok=1

# Overwrite if current value differs from expected (for structural boot vars).
ensure_var() {
    local key="$1" expected="$2" current
    current="$(fw_printenv -n "$key" 2>/dev/null || true)"
    if [ "$current" != "$expected" ]; then
        _setenv "$key" "$expected" || env_ok=0
    fi
}

# Only write if the variable is currently absent (for RAUC state vars).
# RAUC manages BOOT_ORDER/BOOT_x_LEFT after first boot; overwriting them
# would clobber slot selection on the first OTA boot.
_init_if_absent() {
    local key="$1" val="$2" current
    current="$(fw_printenv -n "$key" 2>/dev/null || true)"
    if [ -z "$current" ]; then
        _setenv "$key" "$val" || env_ok=0
    fi
}

# RAUC state vars: initialize only on truly blank env (no existing value).
_init_if_absent "BOOT_ORDER"  "A B"
_init_if_absent "BOOT_A_LEFT" "3"
_init_if_absent "BOOT_B_LEFT" "3"

if [ -f "$ENV_DEFAULTS" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # trim leading/trailing spaces
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        [ -z "$key" ] && continue
        ensure_var "$key" "$val"
    done < "$ENV_DEFAULTS"
else
    log "WARNING: ${ENV_DEFAULTS} missing; skipping managed env migration"
fi

if [ "$env_ok" = "1" ] && fw_printenv >/dev/null 2>&1; then
    touch "$STAMP"
    log "U-Boot env ready"
else
    log "U-Boot env not writable; will retry next boot"
fi
