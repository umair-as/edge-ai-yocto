# shellcheck shell=bash
# RAUC agrees with the cmdline about the booted slot.

edge_check ota.slot-state core "RAUC slot state" chk_rauc_slot

chk_rauc_slot() {
    local status_json booted compat boot_good
    if ! status_json=$(sudo -n rauc status --output-format=json 2>/dev/null); then
        warn "rauc status unreachable (needs sudo)"
        return
    fi
    booted=$(printf '%s' "${status_json}" | sed -n 's/.*"booted":"\([^"]*\)".*/\1/p' | head -1)
    compat=$(printf '%s' "${status_json}" | sed -n 's/.*"compatible":"\([^"]*\)".*/\1/p' | head -1)
    if [ "rootfs.${EDGE_SLOT}" = "${booted}" ] || printf '%s' "${booted}" | grep -qi "${EDGE_SLOT}$"; then
        pass "rauc booted slot '${booted}' agrees with cmdline slot ${EDGE_SLOT}"
    else
        fail "rauc booted slot '${booted:-?}' vs cmdline slot ${EDGE_SLOT} — disagreement"
    fi
    boot_good=$(printf '%s' "${status_json}" | grep -o '"boot_status":"good"' | wc -l)
    info "compatible: ${compat:-unknown}  slots with boot_status=good: ${boot_good}"
}
