# shellcheck shell=bash
# Every board carries an accelerator. With none composed or installed, only a
# bring-up composition (EDGE_ALLOW_NO_ACCEL=1) is acceptable, as a WARN. An
# accelerator no module checks fails here instead of skipping every module.

edge_check accel.none cap:accel:none "Accelerator (none)" chk_accel_none

edge_cap_accel_none() {
    accel_has_module || return 0
    echo "accelerator is ${EDGE_ACCEL}"
    return 1
}

chk_accel_none() {
    if [ "${EDGE_ACCEL_COMPOSED}" = "none" ] && [ "${EDGE_ALLOW_NO_ACCEL}" = "1" ]; then
        warn "no accelerator: bring-up composition (EDGE_ALLOW_NO_ACCEL=1 in /etc/buildinfo); not a product image"
    else
        fail "no accelerator stack installed (composed: ${EDGE_ACCEL_COMPOSED:-unrecorded}) — the accelerator is baseline on every board, so this is a build or composition fault, not an image variant"
    fi
}
