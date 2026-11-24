# shellcheck shell=bash
# RAUC pre-flight: installed, keyring and data directory from system.conf.
# Booted-slot agreement is edge-verity-check.sh's (ota.slot-state).

edge_check ota.rauc core "RAUC pre-flight" chk_rauc

chk_rauc() {
    local keyring datadir
    if ! command -v rauc >/dev/null 2>&1; then
        fail "rauc not installed"
        return
    fi
    pass "rauc: $(rauc --version 2>&1 | head -1)"

    keyring=$(rauc_conf_get "${EDGE_RAUC_CONF}" keyring path directory)
    if [ -n "${keyring}" ] && { [ -f "${keyring}" ] || [ -d "${keyring}" ]; }; then
        pass "keyring present: ${keyring}"
    else
        fail "keyring missing or unreadable: ${keyring:-<unset>}"
    fi

    datadir=$(rauc_conf_get "${EDGE_RAUC_CONF}" system data-directory)
    datadir=${datadir:-/data/rauc}
    if sudo -n test -d "${datadir}" 2>/dev/null; then
        pass "${datadir}/ present (RAUC data-directory)"
    else
        warn "${datadir}/ missing (no slot-state events yet)"
    fi
}
