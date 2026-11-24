# shellcheck shell=bash
# Board identity: the machine and build the remaining checks derive facts from.

edge_check core.identity core "Board identity" chk_identity

chk_identity() {
    if [ -n "${EDGE_MACHINE}" ]; then
        pass "MACHINE=${EDGE_MACHINE} build ${EDGE_BUILD_ID:-?} ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'model unknown'))"
    else
        fail "/etc/buildinfo has no MACHINE= — cannot derive board facts; checks below assume nothing"
    fi
    info "uplink: ${EDGE_UPLINK:-?}  unmanaged:${EDGE_UNMANAGED:- none}"
}
